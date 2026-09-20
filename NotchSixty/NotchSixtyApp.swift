import SwiftUI

@main
struct NotchSixtyApp: App {
    @StateObject private var audioEngine = AudioIOEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: audioEngine)
        }
    }
}
