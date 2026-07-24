import SwiftUI

@main
struct SillageApp: App {
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Transcripts", id: "transcripts") {
            TranscriptsView()
        }
        .windowResizability(.contentMinSize)
    }
}
