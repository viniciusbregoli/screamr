import SwiftUI

/// A dark theme. Color roles are named after Catppuccin's (catppuccin.com/palette) and every theme fills
/// the same roles: `mauve` is the accent, `base`/`mantle`/`crust` the backgrounds from main to darkest,
/// `surface` the controls, `overlay` the dim text and icons, `text`/`subtext0` the readable text.
struct Palette {
    let id: String
    let name: String
    let rosewater, pink, mauve, red, peach, yellow, green, teal, blue, lavender: UInt32
    let text, subtext0, overlay2, overlay1, overlay0, surface1, surface0, base, mantle, crust: UInt32
    /// Neon only: accents glow and a light drifts behind the sidebar.
    var glows = false
}

/// The current theme's colors. Reads the choice from UserDefaults, so every view and the flow bar
/// follow a change made in Settings without passing the theme around.
enum Theme {
    static let key = "theme"

    static let all: [Palette] = [
        Palette(id: "mocha", name: "Catppuccin Mocha",
                rosewater: 0xf5e0dc, pink: 0xf5c2e7, mauve: 0xcba6f7, red: 0xf38ba8, peach: 0xfab387, yellow: 0xf9e2af,
                green: 0xa6e3a1, teal: 0x94e2d5, blue: 0x89b4fa, lavender: 0xb4befe,
                text: 0xcdd6f4, subtext0: 0xa6adc8, overlay2: 0x9399b2, overlay1: 0x7f849c, overlay0: 0x6c7086,
                surface1: 0x45475a, surface0: 0x313244, base: 0x1e1e2e, mantle: 0x181825, crust: 0x11111b),
        // tokyonight.nvim, "night" variant.
        Palette(id: "tokyo-night", name: "Tokyo Night",
                rosewater: 0xc0caf5, pink: 0xff007c, mauve: 0xbb9af7, red: 0xf7768e, peach: 0xff9e64, yellow: 0xe0af68,
                green: 0x9ece6a, teal: 0x1abc9c, blue: 0x7aa2f7, lavender: 0x7dcfff,
                text: 0xc0caf5, subtext0: 0xa9b1d6, overlay2: 0x8089b3, overlay1: 0x737aa2, overlay0: 0x545c7e,
                surface1: 0x3b4261, surface0: 0x292e42, base: 0x1a1b26, mantle: 0x16161e, crust: 0x111118),
        // draculatheme.com/contribute.
        Palette(id: "dracula", name: "Dracula",
                rosewater: 0xf8f8f2, pink: 0xff79c6, mauve: 0xbd93f9, red: 0xff5555, peach: 0xffb86c, yellow: 0xf1fa8c,
                green: 0x50fa7b, teal: 0x8be9fd, blue: 0x8be9fd, lavender: 0xcaa9fa,
                text: 0xf8f8f2, subtext0: 0xc2c3d0, overlay2: 0x8b95c9, overlay1: 0x6272a4, overlay0: 0x565b75,
                surface1: 0x44475a, surface0: 0x343746, base: 0x282a36, mantle: 0x21222c, crust: 0x191a21),
        // rosepinetheme.com/palette, main variant.
        Palette(id: "rose-pine", name: "Rosé Pine",
                rosewater: 0xebbcba, pink: 0xebbcba, mauve: 0xc4a7e7, red: 0xeb6f92, peach: 0xebbcba, yellow: 0xf6c177,
                green: 0x9ccfd8, teal: 0x9ccfd8, blue: 0x9ccfd8, lavender: 0xc4a7e7,
                text: 0xe0def4, subtext0: 0xb8b4d0, overlay2: 0x908caa, overlay1: 0x6e6a86, overlay0: 0x524f67,
                surface1: 0x403d52, surface0: 0x26233a, base: 0x191724, mantle: 0x15131f, crust: 0x100f18),
        // nordtheme.com/docs/colors-and-palettes.
        Palette(id: "nord", name: "Nord",
                rosewater: 0xe5e9f0, pink: 0xb48ead, mauve: 0x88c0d0, red: 0xbf616a, peach: 0xd08770, yellow: 0xebcb8b,
                green: 0xa3be8c, teal: 0x8fbcbb, blue: 0x81a1c1, lavender: 0x81a1c1,
                text: 0xeceff4, subtext0: 0xd8dee9, overlay2: 0x9aa5ba, overlay1: 0x7b88a1, overlay0: 0x616e88,
                surface1: 0x4c566a, surface0: 0x3b4252, base: 0x2e3440, mantle: 0x292e39, crust: 0x242933),
        // github.com/morhetz/gruvbox, dark with medium contrast.
        Palette(id: "gruvbox", name: "Gruvbox Dark",
                rosewater: 0xebdbb2, pink: 0xd3869b, mauve: 0xfabd2f, red: 0xfb4934, peach: 0xfe8019, yellow: 0xfabd2f,
                green: 0xb8bb26, teal: 0x8ec07c, blue: 0x83a598, lavender: 0x83a598,
                text: 0xebdbb2, subtext0: 0xbdae93, overlay2: 0xa89984, overlay1: 0x928374, overlay0: 0x7c6f64,
                surface1: 0x504945, surface0: 0x3c3836, base: 0x282828, mantle: 0x1d2021, crust: 0x161819),
        // After Synthwave '84 (github.com/robb0wen/synthwave-vscode): purple night, hot pink and cyan, glowing.
        Palette(id: "neon", name: "Neon",
                rosewater: 0xf97e72, pink: 0xff7edb, mauve: 0xff7edb, red: 0xfe4450, peach: 0xff8b39, yellow: 0xfede5d,
                green: 0x72f1b8, teal: 0x72f1b8, blue: 0x2de2e6, lavender: 0x36f9f6,
                text: 0xf4eefa, subtext0: 0xbdb4d8, overlay2: 0x9f95c2, overlay1: 0x82789f, overlay0: 0x655c82,
                surface1: 0x3d3157, surface0: 0x2d2444, base: 0x1d1730, mantle: 0x161126, crust: 0x0e0a1a,
                glows: true),
    ]

    private static var cached = all[0]

    static var current: Palette {
        let id = UserDefaults.standard.string(forKey: key) ?? "mocha"
        if cached.id != id { cached = all.first { $0.id == id } ?? all[0] }
        return cached
    }

    static var glows: Bool { current.glows }
    static var rosewater: Color { Color(hex: current.rosewater) }
    static var pink: Color { Color(hex: current.pink) }
    static var mauve: Color { Color(hex: current.mauve) }
    static var red: Color { Color(hex: current.red) }
    static var peach: Color { Color(hex: current.peach) }
    static var yellow: Color { Color(hex: current.yellow) }
    static var green: Color { Color(hex: current.green) }
    static var teal: Color { Color(hex: current.teal) }
    static var blue: Color { Color(hex: current.blue) }
    static var lavender: Color { Color(hex: current.lavender) }
    static var text: Color { Color(hex: current.text) }
    static var subtext0: Color { Color(hex: current.subtext0) }
    static var overlay2: Color { Color(hex: current.overlay2) }
    static var overlay1: Color { Color(hex: current.overlay1) }
    static var overlay0: Color { Color(hex: current.overlay0) }
    static var surface1: Color { Color(hex: current.surface1) }
    static var surface0: Color { Color(hex: current.surface0) }
    static var base: Color { Color(hex: current.base) }
    static var mantle: Color { Color(hex: current.mantle) }
    static var crust: Color { Color(hex: current.crust) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension View {
    /// A soft light around an accent in the Neon theme; other themes are unchanged.
    func glow(_ color: Color, radius: CGFloat = 6) -> some View {
        modifier(Glow(color: color, radius: radius))
    }
}

private struct Glow: ViewModifier {
    let color: Color
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.glows {
            // A tight bright core plus a wide faint halo reads as light rather than a drop shadow.
            content
                .shadow(color: color.opacity(0.8), radius: radius * 0.4)
                .shadow(color: color.opacity(0.4), radius: radius * 1.8)
        } else {
            content
        }
    }
}

/// Neon only: two soft lights drifting behind a surface (the Mac sidebar, the iPhone meeting list).
/// Still when Reduce Motion is on.
struct NeonAmbient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Circle().fill(Theme.mauve.opacity(0.22)).frame(width: 220).blur(radius: 70)
                    .position(x: g.size.width * (drift ? 0.85 : 0.15), y: g.size.height * (drift ? 0.3 : 0.08))
                Circle().fill(Theme.lavender.opacity(0.15)).frame(width: 240).blur(radius: 80)
                    .position(x: g.size.width * (drift ? 0.15 : 0.8), y: g.size.height * (drift ? 0.75 : 0.95))
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: animate)
        .onChange(of: reduceMotion) { animate() }
    }

    /// Also runs when Reduce Motion changes, so the lights stop (or start) right away.
    private func animate() {
        if reduceMotion {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { drift = false }
        } else {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}
