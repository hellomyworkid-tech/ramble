import SwiftUI

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0x6E6E73
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A color with its own dark-mode step.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

/// One color per module, matching the design (white glyphs on these pass 3:1).
enum ModuleColor {
    static let tasks = Color.accentColor
    static let money = Color(hex: "#248A3D")
    static let bills = Color(hex: "#C2570C")
    static let expiry = Color(hex: "#8944AB")
    /// Also used for text (reminder sentences), so dark mode gets a lighter step:
    /// 5.3:1 on a dark card and still 3.2:1 under a white glyph.
    static let notes = Color(light: "#0E7C86", dark: "#2A9DA8")
    /// Key points in notes: the star and label (4.7:1 on its tint), the row tint, and the
    /// highlighter behind marked text (text on it 16.8:1 light, 7.3:1 dark).
    static let keyPoint = Color(light: "#A35F00", dark: "#F2B544")
    static let keyPointTint = Color(light: "#FFF6E0", dark: "#2E2614")
    static let highlighter = Color(light: "#FFDF6B", dark: "#6B5300")
    static let neutral = Color(hex: "#6E6E73")
    static let warning = Color(hex: "#A34700")
}

/// Settings-style rounded square with a white SF Symbol.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

/// "4 天后" pill; turns orange inside a week and red when overdue.
struct CountdownBadge: View {
    let date: Date
    var urgentWithinDays = 7

    var body: some View {
        let days = DayText.daysUntil(date)
        let style: (Color, Color) = {
            if days < 0 { return (.red, Color.red.opacity(0.12)) }
            if days <= urgentWithinDays { return (ModuleColor.warning, Color.orange.opacity(0.14)) }
            return (.secondary, .clear)
        }()
        Text(DayText.countdown(to: date))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(style.0)
            .padding(.horizontal, style.1 == .clear ? 0 : 8)
            .padding(.vertical, 4)
            .background(style.1, in: .capsule)
    }
}

/// Small orange "待确认" tag for fields the AI was unsure about.
struct UncertainTag: View {
    var text: LocalizedStringResource = "待确认"

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModuleColor.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}

/// Thin progress bar for budgets; switches to red when over.
struct BudgetBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(fraction > 1 ? Color.red : fraction > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Asks before deleting one item of a list. A centred alert rather than a confirmation
    /// dialog: on iOS 26 a dialog is a popover pointing at the view it's attached to, which from a
    /// list is the wrong row, and a dialog attached to the row itself doesn't show after a swipe.
    func deletionAlert<Item, Actions: View>(_ title: String, item: Binding<Item?>,
                                            @ViewBuilder actions: @escaping (Item) -> Actions,
                                            message: @escaping (Item) -> Text) -> some View {
        alert(title, isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
              presenting: item.wrappedValue) { value in
            actions(value)
            Button("取消", role: .cancel) {}
        } message: { value in
            message(value)
        }
    }
}

extension View {
    /// An ⓧ at the top-right of a text field that empties it in one tap.
    func clearButton(_ text: Binding<String>, hidden: Bool = false, onClear: (() -> Void)? = nil) -> some View {
        overlay(alignment: .topTrailing) {
            if !hidden, !text.wrappedValue.isEmpty {
                Button("清空", systemImage: "xmark.circle.fill") {
                    text.wrappedValue = ""
                    onClear?()
                }
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(.tertiary)
                .buttonStyle(.borderless)
                .padding(.top, 1)
                .accessibilityLabel("清空内容")
            }
        }
    }
}

extension View {
    /// A short message in a capsule near the bottom that goes away by itself (「已存储到相册」).
    func transientMessage(_ message: Binding<String?>) -> some View {
        modifier(TransientMessage(message: message))
    }
}

private struct TransientMessage: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message).post()
                            try? await Task.sleep(for: .seconds(message.count > 20 ? 4 : 2))
                            self.message = nil
                        }
                }
            }
            .animation(.snappy, value: message)
    }
}

/// Lays its views out in rows, wrapping as needed (suggestion chips, attachment tiles).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
