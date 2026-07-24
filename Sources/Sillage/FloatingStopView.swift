import SwiftUI

/// Contenu du panneau flottant : pastille rouge + chrono + bouton Stop,
/// sur un fond Liquid Glass translucide (macOS 26).
struct FloatingStopView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(controller.elapsedString)
                    .font(.headline)
                    .monospacedDigit()
            }

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.red)
                    .padding(4)
            }
            .buttonStyle(.glass)
            .help("Arrêter l'enregistrement")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .padding(10)   // marge pour le halo du glass
        .fixedSize()
    }
}
