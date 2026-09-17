import SwiftUI

/// The Purse styling reference, used by **checkout mode only** — the playground keeps `DemoTheme`'s
/// greyscale and system font so the two are told apart at a glance.
///
/// The rule that shapes everything below: **Peppermint is the identity colour, not the action
/// colour.** Buttons are ink; Peppermint marks focus rings, selected states and the logo, and never
/// carries white text.
enum PurseDS {

    // MARK: Colour

    /// Primary text, and the fill of every action button.
    static let ink = Color(hex: 0x080810)
    static let textSecondary = Color(hex: 0x52525B)
    static let textSubtle = Color(hex: 0xA1A1AA)

    static let surface = Color.white
    static let surfaceMuted = Color(hex: 0xF8F8F8)
    static let border = Color(hex: 0xEAEAEC)

    /// Peppermint. Identity, not action.
    static let accent = Color(hex: 0x00CEAC)
    static let accentPressed = Color(hex: 0x00A48C)

    static let success = Color(hex: 0x39B869)
    static let danger = Color(hex: 0xEF4444)

    static let disabledFill = Color(hex: 0xF4F4F5)
    /// One shade darker than `ink`, for a pressed action button. Never opacity, never scale.
    static let inkPressed = Color(hex: 0x181B1B)

    /// The focus ring: Peppermint at 35%.
    static let focusRing = Color(hex: 0x00CEAC).opacity(0.35)

    // MARK: Type

    /// The scale, in points: 10, 12, 14 (body), 16, 20, 24, 32.
    enum Size {
        static let micro: CGFloat = 10
        static let caption: CGFloat = 12
        static let body: CGFloat = 14
        static let bodyLarge: CGFloat = 16
        static let title: CGFloat = 20
        static let heading: CGFloat = 24
        static let display: CGFloat = 32
    }

    static func regular(_ size: CGFloat) -> Font { .custom("AlbertSans-Regular", size: size) }
    static func semibold(_ size: CGFloat) -> Font { .custom("AlbertSans-SemiBold", size: size) }

    /// Body is 14/20; SwiftUI takes the gap, not the line height.
    static let bodyLineSpacing: CGFloat = 6

    // MARK: Spacing, radius, elevation

    /// Base-4: 4, 8, 12, 16, 24, 32, 48.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 20
        static let pill: CGFloat = 1000
    }

    /// Borders do the work; the shadow is a lift, not a glow.
    static let cardShadow = Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255).opacity(0.08)
    static let sheetShadow = Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255).opacity(0.16)

    /// 120–200ms ease on colour and shadow. No bounces.
    static let motion: Animation = .easeInOut(duration: 0.16)

    /// The smallest a tap target may be.
    static let minTapTarget: CGFloat = 44
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Icons

/// A Lucide icon, 2px stroke. Template imagesets, so they take `foregroundStyle` like a symbol.
/// Not SF Symbols: a different drawing set with a different weight, and mixing the two shows.
struct PurseIcon: View {
    let name: String
    var size: CGFloat = 24

    init(_ name: String, size: CGFloat = 24) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("lucide-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

// MARK: - Controls

/// The primary action: ink, white text, 48pt as a mobile call to action.
struct PurseButtonStyle: ButtonStyle {
    var height: CGFloat = 48
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PurseDS.semibold(PurseDS.Size.bodyLarge))
            .foregroundStyle(enabled ? Color.white : PurseDS.textSubtle)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, PurseDS.Space.l)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.control))
            .animation(PurseDS.motion, value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        guard enabled else { return PurseDS.disabledFill }
        return pressed ? PurseDS.inkPressed : PurseDS.ink
    }
}

/// The quieter action: a hairline outline, ink text, no fill.
struct PurseSecondaryButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PurseDS.semibold(PurseDS.Size.body))
            .foregroundStyle(enabled ? PurseDS.ink : PurseDS.textSubtle)
            .frame(maxWidth: .infinity, minHeight: PurseDS.minTapTarget)
            .padding(.horizontal, PurseDS.Space.l)
            .background(configuration.isPressed ? PurseDS.surfaceMuted : PurseDS.surface)
            .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: PurseDS.Radius.control)
                    .strokeBorder(PurseDS.border, lineWidth: 1)
            )
            .animation(PurseDS.motion, value: configuration.isPressed)
    }
}

/// A full-width call to action.
struct PurseButton: View {
    let title: String
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PurseDS.Space.s) {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(title)
            }
        }
        .buttonStyle(PurseButtonStyle(enabled: enabled && !loading))
        .disabled(!enabled || loading)
    }
}

struct PurseSecondaryButton: View {
    let title: String
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PurseDS.Space.s) {
                if loading { ProgressView().controlSize(.small) }
                Text(title)
            }
        }
        .buttonStyle(PurseSecondaryButtonStyle(enabled: enabled && !loading))
        .disabled(!enabled || loading)
    }
}

/// A card: hairline border, shadow just off the surface.
struct PurseCard<Content: View>: View {
    var padding: CGFloat = PurseDS.Space.l
    var selected = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PurseDS.Space.m) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(PurseDS.surface)
            .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: PurseDS.Radius.card)
                    .strokeBorder(selected ? PurseDS.accent : PurseDS.border, lineWidth: selected ? 2 : 1)
            )
            .shadow(color: PurseDS.cardShadow, radius: 4, x: 0, y: 4)
            .animation(PurseDS.motion, value: selected)
    }
}

/// A text field with the Peppermint focus ring.
struct PurseField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(PurseDS.regular(PurseDS.Size.body))
        .foregroundStyle(PurseDS.ink)
        .keyboardType(keyboard)
        .focused($focused)
        .padding(.horizontal, PurseDS.Space.m)
        .frame(height: PurseDS.minTapTarget)
        .background(PurseDS.surface)
        .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: PurseDS.Radius.control)
                .strokeBorder(focused ? PurseDS.accent : PurseDS.border, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PurseDS.Radius.control)
                .strokeBorder(PurseDS.focusRing, lineWidth: focused ? 3 : 0)
                .padding(-2)
        )
        .animation(PurseDS.motion, value: focused)
    }
}

/// A section heading.
struct PurseSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(PurseDS.semibold(PurseDS.Size.bodyLarge))
            .foregroundStyle(PurseDS.ink)
            .padding(.top, PurseDS.Space.s)
    }
}
