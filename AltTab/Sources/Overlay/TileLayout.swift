import CoreGraphics

/// Pure tile flow-layout math. Kept separate from OverlayView so wrapping and sizing rules
/// are testable without AppKit, windows, or WindowServer.
enum TileLayout {
    struct Result: Equatable {
        let size: CGSize
        let frames: [CGRect]
    }

    static func calculate(tileWidths: [CGFloat], tileHeight: CGFloat, maxWidth: CGFloat,
                          outerPadding: CGFloat, interTilePadding: CGFloat) -> Result {
        guard !tileWidths.isEmpty else { return Result(size: .zero, frames: []) }
        let contentMaxWidth = max(0, maxWidth - outerPadding * 2)
        let rows = wrappedRows(tileWidths: tileWidths, maxContentWidth: contentMaxWidth, padding: interTilePadding)
        let rowWidths = rows.map { rowWidth(indices: $0, tileWidths: tileWidths, padding: interTilePadding) }
        let widestRow = rowWidths.max() ?? 0
        let totalWidth = widestRow + outerPadding * 2
        let totalHeight = outerPadding * 2 + tileHeight * CGFloat(rows.count) + interTilePadding * CGFloat(max(0, rows.count - 1))
        return Result(size: CGSize(width: totalWidth, height: totalHeight),
                      frames: frames(rows: rows, rowWidths: rowWidths, tileWidths: tileWidths,
                                     widestRow: widestRow, totalHeight: totalHeight, tileHeight: tileHeight,
                                     outerPadding: outerPadding, interTilePadding: interTilePadding))
    }

    private static func wrappedRows(tileWidths: [CGFloat], maxContentWidth: CGFloat, padding: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var currentWidth: CGFloat = 0
        for (i, width) in tileWidths.enumerated() {
            let needed = currentWidth > 0 ? padding + width : width
            if currentWidth + needed > maxContentWidth && !rows[rows.count - 1].isEmpty {
                rows.append([i])
                currentWidth = width
            } else {
                rows[rows.count - 1].append(i)
                currentWidth += needed
            }
        }
        return rows
    }

    private static func rowWidth(indices: [Int], tileWidths: [CGFloat], padding: CGFloat) -> CGFloat {
        return indices.reduce(CGFloat(0)) { $0 + tileWidths[$1] } + CGFloat(max(0, indices.count - 1)) * padding
    }

    private static func frames(rows: [[Int]], rowWidths: [CGFloat], tileWidths: [CGFloat], widestRow: CGFloat,
                               totalHeight: CGFloat, tileHeight: CGFloat, outerPadding: CGFloat,
                               interTilePadding: CGFloat) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: tileWidths.count)
        for (rowIndex, row) in rows.enumerated() {
            var x = outerPadding + (widestRow - rowWidths[rowIndex]) / 2
            let y = totalHeight - outerPadding - tileHeight - CGFloat(rowIndex) * (tileHeight + interTilePadding)
            for tileIndex in row {
                result[tileIndex] = CGRect(x: x, y: y, width: tileWidths[tileIndex], height: tileHeight)
                x += tileWidths[tileIndex] + interTilePadding
            }
        }
        return result
    }
}
