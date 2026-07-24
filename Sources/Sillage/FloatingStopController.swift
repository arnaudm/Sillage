import AppKit
import SwiftUI

/// NSPanel borderless qui peut devenir key (pour que le bouton reçoive les clics)
/// sans activer l'app.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Gère un petit panneau flottant « Stop », toujours visible pendant
/// l'enregistrement (au-dessus des autres fenêtres et espaces).
@MainActor
final class FloatingStopController {
    private var panel: NSPanel?

    func show(controller: RecordingController) {
        if panel == nil {
            panel = makePanel(controller: controller)
        }
        guard let panel else { return }
        positionTopCenter(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: RecordingController) -> NSPanel {
        let hosting = NSHostingView(rootView: FloatingStopView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]   // le panneau se dimensionne au contenu

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar                          // au-dessus des fenêtres normales
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear                    // laisse voir la fenêtre derrière
        panel.isOpaque = false
        panel.hasShadow = false                           // le glass fournit son propre halo
        panel.isMovableByWindowBackground = true          // déplaçable à la souris
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        return panel
    }

    private func positionTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
