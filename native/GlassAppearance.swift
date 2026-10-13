import SwiftUI
import AppKit
import Speech
import AVFoundation
import Translation
import Vision
import NaturalLanguage
import UniformTypeIdentifiers
import ApplicationServices
import Carbon.HIToolbox

enum MacVisualTokens {
    static let accent = Color.accentColor
    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let controlFill = Color(nsColor: .controlBackgroundColor)
    static let panelRadius: CGFloat = 20
    static let controlRadius: CGFloat = 9
    static let floatingRadius: CGFloat = 12
}

/// A single, shared glass recipe used by the window backdrop, title bar and
/// translation card.  The material is rendered first, then the mode-specific
/// tint is placed above it so backdrop content cannot introduce a left/right
/// colour shift.
struct UnifiedGlassLayer: View {
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color
    let materialOpacity: Double
    let isUltraThin: Bool
    var isRegular: Bool = false

    var body: some View {
        Group {
            if glassEnabled {
                ZStack {
                    if isRegular {
                        Rectangle()
                            .fill(.regularMaterial)
                            .opacity(materialOpacity)
                    } else if isUltraThin {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(materialOpacity)
                    } else {
                        Rectangle()
                            .fill(.thinMaterial)
                            .opacity(materialOpacity)
                    }
                    Rectangle()
                        .fill(tint)
                }
            } else {
                Rectangle()
                    .fill(colorScheme == .dark
                        ? Color(red: 0.055, green: 0.065, blue: 0.085)
                        : Color(red: 0.976, green: 0.978, blue: 0.995))
            }
        }
    }
}

struct AdaptiveGlassBackdrop: View {
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    var materialOpacity = 0.88
    var tintOpacity = 0.26
    var regular = true

    var body: some View {
        Group {
            if glassEnabled {
                UnifiedGlassLayer(
                    tint: colorScheme == .dark
                        ? Color.black.opacity(tintOpacity)
                        : Color.white.opacity(tintOpacity),
                    materialOpacity: materialOpacity,
                    isUltraThin: !regular,
                    isRegular: regular
                )
            } else {
                Rectangle()
                    .fill(colorScheme == .dark
                        ? Color(red: 0.10, green: 0.115, blue: 0.145)
                        : Color.white)
            }
        }
    }
}

enum GlassSurfaceLevel: Equatable {
    case card
    case editor
}

struct GlassSurfaceModifier: ViewModifier {
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let level: GlassSurfaceLevel

    private var tintOpacity: Double {
        switch level {
        case .card: return 0.09
        case .editor: return 0.18
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                Group {
                    if glassEnabled {
                        ZStack {
                            if level == .editor {
                                shape.fill(.regularMaterial).opacity(0.94)
                            } else {
                                shape.fill(.thinMaterial).opacity(0.86)
                            }
                            shape.fill(colorScheme == .dark
                                ? Color.black.opacity(tintOpacity)
                                : Color.white.opacity(tintOpacity))
                            shape.stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(colorScheme == .dark ? 0.30 : 0.82),
                                             MacVisualTokens.separator.opacity(0.42)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                        }
                    } else {
                        ZStack {
                            shape.fill(colorScheme == .dark
                                ? Color(red: 0.10, green: 0.115, blue: 0.145)
                                : Color.white)
                            shape.stroke(MacVisualTokens.separator.opacity(0.72), lineWidth: 0.8)
                        }
                    }
                }
            }
            .clipShape(shape)
            .shadow(
                color: glassEnabled
                    ? Color.black.opacity(level == .editor ? (colorScheme == .dark ? 0.22 : 0.10) : 0.07)
                    : Color.black.opacity(0.04),
                radius: glassEnabled ? (level == .editor ? 14 : 8) : 3,
                y: glassEnabled ? (level == .editor ? 6 : 3) : 1
            )
    }
}

struct HoverMaterialModifier: ViewModifier {
    @State private var isHovering = false
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Color.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
            }
    }
}

extension View {
    func macHoverControl(
        cornerRadius: CGFloat = MacVisualTokens.controlRadius,
        horizontalPadding: CGFloat = 9,
        height: CGFloat = 32
    ) -> some View {
        modifier(HoverMaterialModifier(
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            height: height
        ))
    }

    func macGlassBorder(cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(MacVisualTokens.separator.opacity(0.72), lineWidth: 0.75)
        }
    }

    func glassSurface(cornerRadius: CGFloat, level: GlassSurfaceLevel = .card) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, level: level))
    }
}

struct FloatingGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassSurface(cornerRadius: MacVisualTokens.floatingRadius)
            .shadow(color: Color.black.opacity(0.09), radius: 7, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct LanguageSwapButtonStyle: ButtonStyle {
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MacVisualTokens.floatingRadius, style: .continuous)
        configuration.label
            .background {
                if glassEnabled {
                    shape.fill(.ultraThinMaterial).opacity(0.38)
                } else {
                    shape.fill(MacVisualTokens.controlFill.opacity(0.40))
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.34), lineWidth: 0.6)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 3, y: 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
