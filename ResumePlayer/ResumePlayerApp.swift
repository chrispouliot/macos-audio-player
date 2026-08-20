import SwiftUI

@main
struct ResumePlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("ResumePlayer") {
            ContentView()
                .environmentObject(appDelegate.playbackModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") {
                    appDelegate.playbackModel.presentOpenPanel()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Set as Default Audio Player…") {
                    appDelegate.playbackModel.requestDefaultAudioPlayer()
                }
            }
        }
    }
}
