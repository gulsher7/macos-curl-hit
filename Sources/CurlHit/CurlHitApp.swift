import SwiftUI

@main
struct CurlHitApp: App {
    var body: some Scene {
        WindowGroup("Curl Hit") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }   // single-window utility
        }
    }
}
