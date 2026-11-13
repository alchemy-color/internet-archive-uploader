import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 14
    static let pageMaxWidth: CGFloat = 880
    static let pagePadding: CGFloat = 28
}

/// A soft, native-looking content card.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var subtitle: String?
    @Environment(\.memoryScope) private var scope
    @ViewBuilder var content: Content

    /// Collapsed/expanded state is remembered per tab and survives relaunch.
    private var memoryKey: String { "\(scope).card.\(title ?? "")" }
    private var isExpanded: Bool {
        get { ViewMemory.shared.flag(memoryKey, default: true) }
        nonmutating set { ViewMemory.shared.setFlag(memoryKey, newValue) }
    }

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        if let systemImage {
                            Image(systemName: systemImage)
                                .foregroundStyle(.secondary)
                        }
                        Text(title)
                            .font(.headline)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let subtitle, isExpanded {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            if isExpanded || title == nil {
                content
                    .padding(.top, title == nil ? 0 : 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

struct InfoBanner: View {
    enum Kind {
        case info, warning, error, success

        var color: Color {
            switch self {
            case .info: return .accentColor
            case .warning: return .orange
            case .error: return .red
            case .success: return .green
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.color.opacity(0.18))
        )
    }
}

struct FieldLabel: View {
    let text: String
    var required: Bool = false
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.subheadline.weight(.medium))
            if required {
                Text("Required")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if let help {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(help)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(UIScale.font(11, .medium))
        .foregroundStyle(color)
        .padding(.horizontal, UIScale.size(7))
        .padding(.vertical, UIScale.size(2.5))
        .background(color.opacity(0.11), in: Capsule())
    }
}

/// Bottom action bar used by each step.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// A simple wrapping layout used for subject chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x)
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .padding(.horizontal, 24)
    }
}

extension ByteCountFormatter {
    static func shortString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Reference-type anchor used to register undo actions that capture
/// value-type state (such as array bindings).
extension TimeInterval {
    var clockString: String {
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Reference-type anchor used to register undo actions that capture value-type state.
final class UndoAnchor: NSObject {}

// MARK: - UI size

/// One app-wide size control (View ▸ Bigger / Smaller). Rows, icons, headers
/// and badges use these helpers so they scale together.
@MainActor
enum UIScale {
    static let key = "ui.scale"
    static let defaultValue = 1.15
    static let range = 0.9...1.6

    static var value: CGFloat {
        CGFloat(Double(ViewMemory.shared.string(key, default: String(defaultValue))) ?? defaultValue)
    }

    static func set(_ newValue: Double) {
        ViewMemory.shared.setString(key, String(min(max(newValue, range.lowerBound), range.upperBound)))
    }

    static func bigger() { set(Double(value) + 0.1) }
    static func smaller() { set(Double(value) - 0.1) }
    static func reset() { set(defaultValue) }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: (size * value).rounded(), weight: weight, design: design)
    }

    static func size(_ points: CGFloat) -> CGFloat { (points * value).rounded() }
}
