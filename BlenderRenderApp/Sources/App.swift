import SwiftUI

@main
struct BlenderRenderApp: App {
    @StateObject private var state = AppState()

    init() {
        signal(SIGPIPE, SIG_IGN)  // an SSH upload that dies mid-way must not take the app down
    }

    var body: some Scene {
        Window("BlenderRender", id: "main") {
            ContentView().environmentObject(state)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { state.checkForUpdates(manual: true) }
            }
            CommandGroup(replacing: .help) {
                Button("Set Up a Render PC…") { state.showGuide = true }
            }
        }

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}
