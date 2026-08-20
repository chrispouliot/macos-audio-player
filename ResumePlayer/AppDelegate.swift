import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playbackModel = PlaybackModel()
    private var terminationTask: Task<Void, Never>?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor [weak self] in
            await self?.playbackModel.open(url: url)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        playbackModel.saveForInactivity()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            await self?.playbackModel.saveForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
