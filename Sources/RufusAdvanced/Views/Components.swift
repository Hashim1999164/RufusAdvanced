import SwiftUI
import BootKit

/// A titled section card.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                if let trailing { trailing }
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// Label + control row with a fixed label column.
struct FormRow<Content: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .trailing)
                .help(help ?? "")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .accentColor
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }
}

struct InfoLine: View {
    let text: String
    var systemImage = "info.circle"
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(color == .secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

extension DiskInfo.Kind {
    var symbol: String {
        switch self {
        case .usbFlash: return "mediastick"
        case .usbHardDrive: return "externaldrive"
        case .sdCard: return "sdcard"
        case .diskImage: return "opticaldiscdrive"
        case .otherExternal: return "externaldrive.connected.to.line.below"
        case .internalDisk: return "internaldrive"
        }
    }
}

extension ImageReport {
    var symbol: String {
        switch family {
        case .windows: return "squareshape.split.2x2"
        case .linux: return "terminal"
        case .macOS: return "apple.logo"
        case .freeDOS: return "chevron.left.forwardslash.chevron.right"
        default:
            return kind == .compressedDisk ? "doc.zipper" : "opticaldisc"
        }
    }

    var tint: Color {
        switch family {
        case .windows: return .blue
        case .linux: return .orange
        case .macOS: return .gray
        default: return .purple
        }
    }
}
