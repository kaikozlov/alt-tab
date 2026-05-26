import CoreGraphics

func testTileLayout() {
    runTests("TileLayout") {
        let empty = TileLayout.calculate(tileWidths: [], tileHeight: 50, maxWidth: 200, outerPadding: 10, interTilePadding: 5)
        expect(empty.size == .zero, "empty layout has zero size")
        expect(empty.frames.isEmpty, "empty layout has no frames")
        let single = TileLayout.calculate(tileWidths: [100], tileHeight: 50, maxWidth: 200, outerPadding: 10, interTilePadding: 5)
        expectEqual(single.size.width, 120, "single tile width includes outer padding")
        expectEqual(single.size.height, 70, "single tile height includes outer padding")
        expect(single.frames == [CGRect(x: 10, y: 10, width: 100, height: 50)], "single tile at padding origin")
        let row = TileLayout.calculate(tileWidths: [80, 90], tileHeight: 40, maxWidth: 220, outerPadding: 10, interTilePadding: 5)
        expectEqual(row.size.width, 195, "same-row width includes padding")
        expect(row.frames[0] == CGRect(x: 10, y: 10, width: 80, height: 40), "first tile at left padding")
        expect(row.frames[1] == CGRect(x: 95, y: 10, width: 90, height: 40), "second tile follows spacing")
        let wrapped = TileLayout.calculate(tileWidths: [120, 120, 80], tileHeight: 40, maxWidth: 270, outerPadding: 10, interTilePadding: 5)
        expectEqual(wrapped.size.width, 265, "wrapped width is widest row plus padding")
        expectEqual(wrapped.size.height, 105, "wrapped height includes both rows")
        expect(wrapped.frames[0] == CGRect(x: 10, y: 55, width: 120, height: 40), "first wrapped tile on top row")
        expect(wrapped.frames[2] == CGRect(x: 92.5, y: 10, width: 80, height: 40), "short row is centered")
    }
}
