import AppKit
import SwiftUI

/// Shared look for Settings and onboarding: grouped cards with title/subtitle rows and controls on the right,
/// coloured icon tiles, and large page headers.
enum Brand {
    static let green = Color(red: 0x17 / 255, green: 0xCF / 255, blue: 0x97 / 255)
}

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.92), color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Calendar-page style date tile ("NOV / 5").
struct DateTile: View {
    var size: CGFloat = 56
    var date = Date()
    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: size * 0.2, weight: .bold)).foregroundStyle(.secondary)
                .padding(.top, size * 0.08)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: size * 0.46, weight: .medium))
            Spacer(minLength: 0)
        }
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [Color(white: 1), Color(white: 0.93)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .foregroundStyle(Color.black)
        .accessibilityHidden(true)
    }
}

struct PageHeader<Icon: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var icon: Icon
    var body: some View {
        VStack(spacing: 8) {
            icon
            Text(title).font(.system(size: 26, weight: .bold)).padding(.top, 6)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

struct GroupLabel: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Footnote: View {
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact macOS switch with no label (the row provides it).
struct Switch: View {
    @Binding var isOn: Bool
    var label: String
    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).accessibilityLabel(label)
    }
}

struct StatusPill: View {
    var text: String
    var ok: Bool
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ok ? Brand.green : .secondary)
    }
}

/// Illustrated choice between menu-bar and notch presentation (used in Settings and onboarding).
struct PresentationModePicker: View {
    @Binding var mode: PresentationMode
    var body: some View {
        HStack(spacing: 14) {
            card(.menuBar)
            card(.notch)
        }
    }

    func card(_ m: PresentationMode) -> some View {
        let selected = mode == m
        return Button { mode = m } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: m == .menuBar ? [Color(red: 0.36, green: 0.62, blue: 0.98), Color(red: 0.18, green: 0.38, blue: 0.85)]
                                                                     : [Color(white: 0.55), Color(white: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    // Menu bar strip
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 9)
                    if m == .menuBar {
                        HStack { Spacer(); Capsule().fill(.white).frame(width: 46, height: 5).padding(.trailing, 14).padding(.top, 2) }
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.92)).frame(width: 62, height: 40)
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 6).padding(.top, 13)
                    } else {
                        UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5).fill(.black).frame(width: 64, height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.92)).frame(width: 70, height: 40).padding(.top, 15)
                    }
                }
                .frame(width: 150, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(m.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(selected ? Color.primary.opacity(0.1) : .clear, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.label) presentation")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Rounded content container that fills the remaining height (editors, transcript, summary).
struct ContentCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(scheme == .dark ? Color.white.opacity(0.04) : Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

struct PillButton: View {
    var title: String
    var icon: String
    var prominent = false
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(prominent ? Brand.green : Color.primary.opacity(hover ? 0.1 : 0.06), in: Capsule())
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PillToggle: View {
    var title: String
    var icon: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
