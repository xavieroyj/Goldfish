import SwiftUI

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let foreground: Color = kind == .primary ? Color.canvas : Color.ink
        let background: Color = {
            switch kind {
            case .primary: Color.mint
            case .secondary: Color.raised
            case .danger: Color.coral.opacity(0.15)
            }
        }()
        return configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(kind == .danger ? Color.coral : foreground)
            .padding(.horizontal, 12).frame(height: 32)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(kind == .secondary ? Color.border : Color.clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct SectorMapView: View {
    let progress: ScanProgress

    var body: some View {
        Canvas { context, size in
            let columns = 64
            let rows = 5
            let horizontalGap: CGFloat = 3
            let verticalGap: CGFloat = 3
            let cellWidth = (size.width - CGFloat(columns - 1) * horizontalGap) / CGFloat(columns)
            let cellHeight = (size.height - CGFloat(rows - 1) * verticalGap) / CGFloat(rows)
            let count = columns * rows
            for index in 0..<count {
                let start = UInt64(Double(progress.total) * Double(index) / Double(count))
                let end = UInt64(Double(progress.total) * Double(index + 1) / Double(count))
                let color: Color
                if overlaps(start, end, progress.readErrors) {
                    color = .coral
                } else if overlaps(start, end, progress.candidateRanges) {
                    color = .blue
                } else if overlaps(start, end, progress.scannedRanges) {
                    color = .mint.opacity(0.66)
                } else {
                    color = .raised
                }
                let x = CGFloat(index % columns) * (cellWidth + horizontalGap)
                let y = CGFloat(index / columns) * (cellHeight + verticalGap)
                let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .accessibilityLabel("Scan map. Blue shows possible file data, green shows scanned areas, red shows read errors, and dark blocks are not scanned.")
    }

    private func overlaps(_ start: UInt64, _ end: UInt64, _ ranges: [ScannedRange]) -> Bool {
        ranges.contains { $0.start < end && $0.end > start }
    }
}
