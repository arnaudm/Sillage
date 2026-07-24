import SwiftUI
import CoreAudio

struct ContentView: View {
    @EnvironmentObject var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sillage").font(.headline)

            Picker("Micro", selection: $controller.selectedInputDeviceID) {
                Text("Défaut système").tag(AudioDeviceID?.none)
                ForEach(controller.inputDevices) { device in
                    Text(device.name).tag(AudioDeviceID?.some(device.id))
                }
            }
            .disabled(controller.isRecording)

            Toggle("Capturer le son système", isOn: $controller.captureSystemAudio)
                .disabled(controller.isRecording)

            Divider()

            HStack {
                Button(controller.isRecording ? "Arrêter" : "Démarrer") {
                    controller.toggle()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                if controller.isRecording {
                    Text(controller.elapsedString)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "transcripts")
            } label: {
                Label("Voir les transcripts", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            HStack {
                Button("Rafraîchir") { controller.refreshDevices() }
                Spacer()
                Button("Quitter") { confirmQuit() }
            }
            .font(.caption)
        }
        .padding()
        .frame(width: 320)
    }

    /// Demande confirmation avant de quitter (alerte modale, avec avertissement
    /// renforcé si un enregistrement est en cours).
    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Quitter Sillage ?"
        alert.informativeText = controller.isRecording
            ? "Un enregistrement est en cours — il sera interrompu et perdu."
            : "Voulez-vous vraiment quitter l'application ?"
        alert.alertStyle = controller.isRecording ? .warning : .informational
        alert.addButton(withTitle: "Quitter")
        alert.addButton(withTitle: "Annuler")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }
}
