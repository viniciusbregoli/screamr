import AppKit
import SwiftUI

/// Wispr's flow bar: a small pill at the bottom of the screen while dictating. Bars follow the mic
/// level while listening (outlined in mauve when hands-free), dots pulse while Scribe transcribes.
/// The panel never takes focus and lets clicks through, so the paste still lands in the right app.
final class FlowBar {
    enum Mode { case listening, locked, transcribing }

    final class Model: ObservableObject {
        @Published var mode = Mode.listening
        @Published var visible = false
        var level: () -> Float = { 0 }
    }

    private let model = Model()
    private lazy var panel = makePanel()

    /// Mic level from 0 to 1, read on every frame while listening.
    var level: () -> Float {
        get { model.level }
        set { model.level = newValue }
    }

    func show(_ mode: Mode) {
        model.mode = mode
        guard !model.visible else { return }
        model.visible = true
        // On the screen the user is working on, which is where the pointer usually is.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 16))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard model.visible else { return }
        model.visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [panel] in
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: FlowBarView(model: model))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

struct FlowBarView: View {
    @ObservedObject var model: FlowBar.Model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.visible)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Group {
                if model.mode == .transcribing { dots(t) } else { bars(t) }
            }
            .frame(width: 96, height: 30)
            .background(Capsule().fill(Mocha.crust.opacity(0.94)))
            .overlay(Capsule().strokeBorder(model.mode == .locked ? Mocha.mauve : Mocha.surface1, lineWidth: 1))
        }
        .padding(6) // room for the shadow
    }

    /// Each bar rides its own slow wave, scaled by the live level, so silence is a flat line.
    private func bars(_ t: TimeInterval) -> some View {
        let level = CGFloat(model.level())
        return HStack(spacing: 3) {
            ForEach(0..<9) { i in
                let wave = 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.8)
                Capsule()
                    .fill(model.mode == .locked ? Mocha.mauve : Mocha.text)
                    .frame(width: 3, height: 3 + 15 * level * CGFloat(wave))
            }
        }
    }

    private func dots(_ t: TimeInterval) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Mocha.text)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.9)))
            }
        }
    }
}
