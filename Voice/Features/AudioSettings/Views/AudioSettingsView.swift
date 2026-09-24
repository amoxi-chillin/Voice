import CoreAudio
import SwiftUI

struct AudioSettingsView: View {
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @State private var microphoneSourceBeforePriorityOrder: MicrophoneSourceSelection = .systemDefault

    var body: some View {
        Form {
            Section("Input") {
                inputSettingsRows
            }

            if usesPriorityOrder {
                Section {
                    priorityOrderRows
                } header: {
                    Text("Priority Order")
                } footer: {
                    Text("The first available microphone in the list is used.")
                }
            }

            Section("While Recording") {
                Toggle("Mute System Audio", isOn: $mediaController.isSystemMuteEnabled)

                Toggle("Pause Media", isOn: $playbackController.isPauseMediaEnabled)

                resumeDelayMenu
                    .disabled(!canEditResumeDelay)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !usesPriorityOrder {
                microphoneSourceBeforePriorityOrder = currentMicrophoneSource
            }
        }
    }

    @ViewBuilder
    private var inputSettingsRows: some View {
        Picker("Microphone", selection: inputRouteSelection) {
            Text("Selected").tag(InputRoute.singleMicrophone)
            Text("Priority Order").tag(InputRoute.priorityOrder)
        }
        .pickerStyle(.segmented)

        if !usesPriorityOrder {
            Picker("Input Device", selection: microphoneSourceSelection) {
                Text(systemDefaultSourceTitle).tag(MicrophoneSourceSelection.systemDefault)

                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Text(device.name).tag(MicrophoneSourceSelection.device(device.uid))
                }
            }
        }

        LabeledContent("Available Microphones") {
            Button("Refresh") {
                audioDeviceManager.loadAvailableDevices()
            }
        }
    }

    @ViewBuilder
    private var priorityOrderRows: some View {
        if prioritizedDevicesInDisplayOrder.isEmpty {
            Text("Add microphones in the order Voice should try them.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prioritizedDevicesInDisplayOrder) { device in
                priorityDeviceRow(for: device)
            }
        }

        if !availableDevicesNotInPriorityOrder.isEmpty {
            ForEach(availableDevicesNotInPriorityOrder, id: \.uid) { device in
                availablePriorityDeviceRow(for: device)
            }
        }
    }

    private var inputRouteSelection: Binding<InputRoute> {
        Binding(
            get: { usesPriorityOrder ? .priorityOrder : .singleMicrophone },
            set: { route in
                switch route {
                case .singleMicrophone:
                    selectSingleMicrophoneMode()
                case .priorityOrder:
                    selectPriorityOrderMode()
                }
            }
        )
    }

    private var microphoneSourceSelection: Binding<MicrophoneSourceSelection> {
        Binding(
            get: { currentMicrophoneSource },
            set: { selection in
                microphoneSourceBeforePriorityOrder = selection
                selectMicrophoneSource(selection)
            }
        )
    }

    private func availablePriorityDeviceRow(for device: (id: AudioDeviceID, uid: String, name: String)) -> some View {
        Button {
            audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
        } label: {
            Label(device.name, systemImage: "plus.circle")
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("Add to Priority Order")
    }

    private func priorityDeviceRow(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first { $0.uid == prioritizedDevice.id }
        let isAvailable = device != nil
        let isActive = device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false

        return HStack(spacing: 8) {
            Text("\(prioritizedDevice.priority + 1)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(prioritizedDevice.name)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                    .lineLimit(1)

                if !isAvailable {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: 4) {
                Button {
                    movePrioritizedDeviceUp(prioritizedDevice)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.first?.id)
                .help("Move up")

                Button {
                    movePrioritizedDeviceDown(prioritizedDevice)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.last?.id)
                .help("Move down")

                Button {
                    audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var currentMicrophoneSource: MicrophoneSourceSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .custom:
            if let selectedDeviceUID {
                return .device(selectedDeviceUID)
            }
            return .systemDefault
        case .prioritized:
            return microphoneSourceBeforePriorityOrder
        }
    }

    private func selectMicrophoneSource(_ selection: MicrophoneSourceSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .device(let uid):
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else {
                audioDeviceManager.selectInputMode(.systemDefault)
                return
            }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        }
    }

    private func selectSingleMicrophoneMode() {
        selectMicrophoneSource(microphoneSourceBeforePriorityOrder)
    }

    private func selectPriorityOrderMode() {
        if !usesPriorityOrder {
            microphoneSourceBeforePriorityOrder = currentMicrophoneSource
        }
        audioDeviceManager.selectInputMode(.prioritized)
    }

    private var selectedDeviceUID: String? {
        guard let selectedDeviceID = audioDeviceManager.selectedDeviceID else { return nil }
        return audioDeviceManager.availableDevices.first { $0.id == selectedDeviceID }?.uid
    }

    private var systemDefaultSourceTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "System Default")
        }
        return String(format: String(localized: "System Default (%@)"), name)
    }

    private var usesPriorityOrder: Bool {
        audioDeviceManager.inputMode == .prioritized
    }

    private var prioritizedDevicesInDisplayOrder: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var availableDevicesNotInPriorityOrder: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    private var resumeDelayMenu: some View {
        Picker("Resume Delay", selection: $mediaController.audioResumptionDelay) {
            Text("None").tag(0.0)
            Text("1 second").tag(1.0)
            Text("2 seconds").tag(2.0)
            Text("3 seconds").tag(3.0)
            Text("4 seconds").tag(4.0)
            Text("5 seconds").tag(5.0)
        }
    }

    private var canEditResumeDelay: Bool {
        mediaController.isSystemMuteEnabled || playbackController.isPauseMediaEnabled
    }

    private func movePrioritizedDeviceUp(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex > 0
        else { return }

        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }

    private func movePrioritizedDeviceDown(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex < devices.count - 1
        else { return }

        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }

    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

private enum MicrophoneSourceSelection: Hashable {
    case systemDefault
    case device(String)
}

private enum InputRoute: Hashable {
    case singleMicrophone
    case priorityOrder
}
