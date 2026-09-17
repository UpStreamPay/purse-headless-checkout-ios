import SwiftUI

/// Fixed header, scrolling body, pinned bottom action.
struct DemoScreen<Content: View, Action: View>: View {
    let step: Int
    let title: String
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bottomAction: () -> Action

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(step: step, title: title, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            VStack { bottomAction() }
                .padding(20)
                .background(.bar)
        }
        .background(DemoTheme.background)
    }
}

struct ScreenHeader: View {
    /// The playground's wizard position. `nil` in checkout mode: a shopper is not on "step 2 of 3".
    var step: Int?
    let title: String
    /// Replaces the step label when there is no step — a plain line of shopper-facing context.
    var subtitle: String?
    var onBack: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "arrow.left") }
                    .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                if let step {
                    Text("Step \(step) of 3").font(.caption).foregroundStyle(.secondary)
                } else if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Text(title).font(.largeTitle.weight(.semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .tint(DemoTheme.accentTint)
    }
}

struct DemoCard<Content: View>: View {
    var tinted = false
    var selected = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(tinted ? DemoTheme.accentTint.opacity(0.08) : DemoTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            // An outline, never a tint: a selected row's body hosts a partner's own UI, whose
            // colours this demo does not control and cannot safely put on a coloured surface.
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(DemoTheme.accentTint, lineWidth: selected ? 2 : 0)
            )
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).padding(.top, 4)
    }
}

struct Disclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack {
                    Text(open ? "▾" : "▸").font(DemoTheme.mono)
                    Text(title).font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}

struct MonoBlock: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView(.horizontal) {
            Text(text).font(DemoTheme.mono).textSelection(.enabled)
        }
        .frame(maxHeight: 280)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(mono ? DemoTheme.mono : .body).textSelection(.enabled)
        }
    }
}

struct BigButton: View {
    let text: String
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(text).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(DemoTheme.accentTint)
        .disabled(!enabled || loading)
    }
}

struct SmallButton: View {
    let text: String
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(text)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(DemoTheme.accentTint)
        .disabled(!enabled || loading)
    }
}

struct ErrorCard: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        DemoCard {
            Text(message).font(.footnote).foregroundStyle(DemoTheme.failure).textSelection(.enabled)
        }
    }
}

struct EventLog: View {
    let events: [String]

    var body: some View {
        DemoCard {
            Disclosure(title: "Event log (\(events.count))") {
                if events.isEmpty {
                    Text("Nothing yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    MonoBlock(events.joined(separator: "\n"))
                }
            }
        }
    }
}

/// Blocks the whole screen while a payment is in flight.
struct BusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Submitting payment…").foregroundStyle(.white)
            }
        }
    }
}
