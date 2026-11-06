import AppKit
import FlowCore
import SwiftUI

/// The non-activating panel from the "not built yet" list — shown near the caret
/// while capturing, a live level graph, gone the instant you're not. Must stay
/// `.nonactivatingPanel`: stealing focus would mean Pour injects the transcript into
/// its own HUD instead of the app you were dictating into.
@MainActor
final class HUDController {

    private let model: AppModel
    private var panel: NSPanel?
    private static let size = NSSize(width: 280, height: 112)

    init(model: AppModel) {
        self.model = model
        model.addStateObserver { [weak self] state in
            switch state {
            case .capturing, .finishing, .refining, .injecting:
                self?.show()
            case .idle:
                // Leave a brief, reassuring delivery confirmation without blocking
                // the next dictation (the controller is already idle).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard self?.model.dictationState == .idle else { return }
                    self?.hide()
                }
            default:
                self?.hide()
            }
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false // pourShadow's glow already reads as elevation
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        // NSPanel defaults to hiding (and, practically, freezing its render loop)
        // whenever the owning app isn't active — which is the entire point of Pour:
        // you're dictating into whatever app IS frontmost. Without this the HUD
        // would show once and then never update again the moment focus left Pour.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: HUDContentView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = Self.size
        let origin: NSPoint
        if let target = model.controller.targetFrame {
            // Below-left of the focused field, the way Wispr Flow and friends park it.
            origin = NSPoint(x: target.minX, y: target.minY - size.height - 10)
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 28)
        }

        // Keep it on-screen if the caret's near an edge.
        if let screen = NSScreen.screens.first(where: { NSPointInRect(origin, $0.frame) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            let clampedX = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
            let clampedY = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            panel.setFrameOrigin(origin)
        }
    }
}
