import CoreAudio
import Foundation

final class MediaController: ObservableObject {

    static let shared = MediaController()

    private static let didMuteSystemAudioKey = "didMuteSystemAudioForRecording"

    // Persisted so a crash or forced quit during a recording can't leave the Mac muted.
    private var didMuteAudio = false {
        didSet { UserDefaults.standard.set(didMuteAudio, forKey: Self.didMuteSystemAudioKey) }
    }
    private var wasAudioMutedBeforeRecording = false
    private var unmuteTask: Task<Void, Never>?
    private var muteGeneration: Int = 0

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {}

    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        unmuteTask?.cancel()
        unmuteTask = nil
        muteGeneration += 1

        let currentlyMuted = isSystemAudioMuted()

        if currentlyMuted {
            if didMuteAudio {
                // We muted it previously, stay responsible for unmuting
                wasAudioMutedBeforeRecording = false
            } else {
                // User muted it, don't unmute when done
                wasAudioMutedBeforeRecording = true
                didMuteAudio = false
            }
            return true
        }

        wasAudioMutedBeforeRecording = false
        let success = setSystemMuted(true)
        didMuteAudio = success
        return success
    }

    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        let delay = audioResumptionDelay
        let shouldUnmute = didMuteAudio && !wasAudioMutedBeforeRecording
        let myGeneration = muteGeneration

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            guard self.muteGeneration == myGeneration else { return }

            if shouldUnmute {
                _ = self.setSystemMuted(false)
            }

            self.didMuteAudio = false
        }

        unmuteTask = task
        await task.value
    }

    /// Unmutes right away, skipping the resumption delay, when the app quits during or just after a recording.
    func restoreSystemAudioBeforeTermination() {
        unmuteTask?.cancel()
        unmuteTask = nil
        muteGeneration += 1

        if didMuteAudio && !wasAudioMutedBeforeRecording {
            _ = setSystemMuted(false)
        }
        didMuteAudio = false
    }

    /// Unmutes system audio that a previous run muted for recording but never restored.
    func restoreSystemAudioAfterUnexpectedExit() {
        guard UserDefaults.standard.bool(forKey: Self.didMuteSystemAudioKey) else { return }

        if isSystemAudioMuted() {
            _ = setSystemMuted(false)
        }
        UserDefaults.standard.removeObject(forKey: Self.didMuteSystemAudioKey)
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    private func isSystemAudioMuted() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted)
        return status == noErr && muted != 0
    }

    private func setSystemMuted(_ muted: Bool) -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if status != noErr || !isSettable.boolValue { return false }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue)
        return status == noErr
    }
}
