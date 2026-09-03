import SwiftUI

@main
struct SillageApp: App {
    @StateObject private var controller = RecordingController()
    @StateObject private var selection = TranscriptSelection()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(controller)
                .environmentObject(selection)
        } label: {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Transcripts", id: "transcripts") {
            TranscriptsView()
                .environmentObject(controller)
                .environmentObject(selection)
        }
        .windowResizability(.contentMinSize)
    }
}
