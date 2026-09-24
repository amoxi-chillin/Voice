import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    weak var engine: VoiceInkEngine?

    private var isTerminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MediaController.shared.restoreSystemAudioAfterUnexpectedExit()
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine, engine.hasActiveRecording else { return .terminateNow }

        // Close the recording file before quitting so the dictation can be retranscribed on next launch.
        isTerminationReplyPending = true
        Task { @MainActor in
            await engine.finishRecordingForTermination()
            self.replyToPendingTermination()
        }
        // Never hold up quit or logout if stopping the recorder hangs.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.replyToPendingTermination()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaController.shared.restoreSystemAudioBeforeTermination()
    }

    private func replyToPendingTermination() {
        guard isTerminationReplyPending else { return }
        isTerminationReplyPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.currentMainWindow() != nil {
                WindowManager.shared.showMainWindow()
                return false
            }

            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            return false
        }

        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }

        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI's main window scene and let ContentView process this later.
            pendingOpenFileURL = url
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            WindowManager.shared.showMainWindow()
            NotificationCenter.default.post(
                name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
