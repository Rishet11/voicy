import SwiftUI
import AppKit

// MARK: - Theme (design system)
//
// The single source of visual truth for every UI view. Nothing in UI/ should
// hardcode a spacing, radius, font, color, shadow or duration; everything
// derives from this file. Tokens are drawn from the Raycast / Linear dark
// glass language: near-black layered surfaces, a signature "lit top edge"
// highlight, 5% hairline borders and pill-shaped primary actions.
//
// Every color is adaptive (dark + light) so the premium look survives a
// system appearance change. Every animation respects accessibilityReduceMotion.

/// Namespace for the whole design system.
enum Theme {

    // MARK: Spacing (Raycast/Linear-derived, compact for a menubar companion)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii (pill = Linear's 9999px buttons)

    enum Corner {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        /// Fully rounded — Linear's `borderRadius: 9999px` pill.
        static let pill: CGFloat = 9999
    }

// MARK: Typography ramp (SF Pro, per role)

    enum Typography {
        /// The dominant name on a resolved card.
        static func display(_ weight: Font.Weight = .bold) -> Font {
            .system(size: 28, weight: weight, design: .rounded)
        }
        /// Section / "Which …?" headline.
        static func title(_ weight: Font.Weight = .bold) -> Font {
            .system(size: 22, weight: weight, design: .rounded)
        }
        /// Card header line.
        static func headline(_ weight: Font.Weight = .semibold) -> Font {
            .system(size: 15, weight: weight)
        }
        /// Primary body text.
        static func body(_ weight: Font.Weight = .regular) -> Font {
            .system(size: 14, weight: weight)
        }
        /// Secondary / supporting text.
        static func callout(_ weight: Font.Weight = .regular) -> Font {
            .system(size: 13, weight: weight)
        }
        /// Quiet captions + tiny labels.
        static func caption(_ weight: Font.Weight = .regular) -> Font {
            .system(size: 12, weight: weight)
        }
        /// Micro labels (uppercased eyebrows).
        static func micro(_ weight: Font.Weight = .semibold) -> Font {
            .system(size: 11, weight: weight)
        }
        /// Key-cap glyphs (monospaced for a mechanical feel).
        static func keycap(_ weight: Font.Weight = .semibold) -> Font {
            .system(size: 11, weight: weight, design: .monospaced)
        }
    }
// MARK: Semantic colors (adaptive)

    struct Colors {
        struct Palette {
            var backgroundDeep: Color
            var surface: Color          // input / inset wells
            var surfaceElevated: Color  // the card itself
            var border: Color           // hairline
            var borderStrong: Color
            var textPrimary: Color
            var textSecondary: Color
            var textTertiary: Color
            var accent: Color           // confirm / action
            var live: Color             // the "voice alive" moment (warm coral)
            var liveSoft: Color
            var success: Color
            var destructive: Color
        }

        /// Linear card `#0f1011` + border `#ffffff0d` in dark; mirrored in light.
        static func palette(_ scheme: ColorScheme) -> Palette {
            switch scheme {
            case .light:
                return Palette(
                    backgroundDeep: Color(hex: 0xF2F3F5),
                    surface: Color(hex: 0xF7F8F8),
                    surfaceElevated: Color.white,
                    border: Color.black.opacity(0.10),
                    borderStrong: Color.black.opacity(0.16),
                    textPrimary: Color(hex: 0x151618),
                    textSecondary: Color.black.opacity(0.58),
                    textTertiary: Color.black.opacity(0.36),
                    accent: Palettes.indigo,
                    live: Palettes.coral,
                    liveSoft: Palettes.coral.opacity(0.15),
                    success: Palettes.green,
                    destructive: Palettes.red
                )
            case .dark:
                return Palette(
                    backgroundDeep: Color(hex: 0x07080A),         // Raycast bg
                    surface: Color(hex: 0x0B0C0E),                // input wells
                    surfaceElevated: Color(hex: 0x0F1011),         // Linear card
                    border: Color.white.opacity(0.06),
                    borderStrong: Color.white.opacity(0.12),
                    textPrimary: Color(hex: 0xF7F8F8),             // Linear text
                    textSecondary: Color.white.opacity(0.62),
                    textTertiary: Color.white.opacity(0.38),
                    accent: Palettes.indigo,
                    live: Palettes.coral,
                    liveSoft: Palettes.coral.opacity(0.16),
                    success: Palettes.green,
                    destructive: Palettes.red
                )
            @unknown default:
                return palette(.dark)
            }
        }

        /// Warm, deterministic avatar tints — human, curated, never alarming.
        static let avatarTints: [Color] = [
            Color(hex: 0x5E6AD2), // indigo
            Color(hex: 0xF27A8D), // rose
            Color(hex: 0x2E9E8F), // teal
            Color(hex: 0xE0A13C), // amber
            Color(hex: 0x7B61E0), // violet
            Color(hex: 0x3E8FD0), // ocean
            Color(hex: 0xD67B5B), // clay
            Color(hex: 0x7CA85C), // moss
        ]

        /// Deterministic, stable tint for a name (same person → same colour).
        static func tint(for identifier: String) -> Color {
            let hash = abs(identifier.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 100_000 })
            return avatarTints[hash % avatarTints.count]
        }
    }
// MARK: Motion — springs, never linear fades; reduceMotion respected.

    enum Motion {
        /// Snappy settle for the confirm card.
        static let standard = Animation.spring(response: 0.32, dampingFraction: 0.80)
        /// Entrance for the recording indicator (feels like it "lifts" down).
        static let lift = Animation.spring(response: 0.38, dampingFraction: 0.82)
        /// Small element pops (wave bars).
        static let snappy = Animation.interpolatingSpring(stiffness: 220, damping: 22)
        /// The breathing halo on the live dot.
        static let breathing = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

        /// Pick a spring, or `nil` (no animation) when reduce-motion is on.
        static func driving<T: Equatable>(_ reduce: Bool, _ value: T,
                                          _ spring: Animation = standard) -> Animation? {
            reduce ? nil : spring
        }

        /// A value-driven spring that only animates when motion is allowed.
        static func value<T: Equatable>(_ reduce: Bool, _ value: T) -> Animation? {
            reduce ? nil : snappy
        }
    }

    // MARK: Shared surface shadow: a genuine drop + the "lit top edge" glass
    // highlight (the Raycast signature that makes dark glass read premium).

    static func surfaceShadow(_ scheme: ColorScheme) -> some ViewModifier {
        SurfaceShadowModifier(scheme: scheme)
    }

    struct SurfaceShadowModifier: ViewModifier {
        let scheme: ColorScheme
        func body(content: Content) -> some View {
            content
                .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.14),
                        radius: 22, x: 0, y: 10)
                .overlay {
                    // Lit top edge — a 1 px light gradient just under the rim.
                    RoundedRectangle(cornerRadius: Corner.lg, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    (scheme == .dark ? Color.white : Color.black).opacity(scheme == .dark ? 0.14 : 0.06),
                                    .clear
                                ],
                                startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                            lineWidth: 1
                        )
                }
        }
    }

    /// A hairline border stroke for any surface.
    static func border(_ color: Color) -> some ViewModifier {
        BorderModifier(color: color, radius: Corner.lg)
    }

    struct BorderModifier: ViewModifier {
        let color: Color
        let radius: CGFloat
        func body(content: Content) -> some View {
            content.overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: 1))
        }
    }
}

// MARK: - Private palette

private enum Palettes {
    /// Linear-style action accent (indigo).
    static let indigo = Color(hex: 0x6C6CFF)
    /// A warm coral that reads "alive / voice", not "alarm red".
    static let coral = Color(hex: 0xFF6E53)
    static let green = Color(hex: 0x31C48D)
    static let red = Color(hex: 0xFF4D4D)
}

// MARK: - Colour helper

extension Color {
    /// Build a Color from a 0xRRGGBB integer (no alpha component).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
