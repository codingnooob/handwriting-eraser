import Testing
@testable import HandwritingEraserKit

struct PageRasterTests {
    private func solid(_ width: Int, _ height: Int, _ color: (UInt8, UInt8, UInt8)) -> PageRaster {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = color.0
            pixels[i * 4 + 1] = color.1
            pixels[i * 4 + 2] = color.2
        }
        return PageRaster(width: width, height: height, pixels: pixels)
    }

    @Test func rasterRoundTripsWithoutFlippingRows() throws {
        var image = solid(3, 2, (255, 255, 255))
        image.pixels[0] = 1
        image.pixels[(image.width * (image.height - 1)) * 4 + 2] = 17
        let roundTrip = try PageRaster(image: image.cgImage())
        #expect(roundTrip.width == 3 && roundTrip.height == 2)
        #expect(roundTrip.pixels == image.pixels)
    }

    @Test func maskDilationAndResizeAreBounded() {
        var pixels = [UInt8](repeating: 0, count: 25)
        pixels[0] = 1
        let mask = InkMask(width: 5, height: 5, pixels: pixels).dilated(radius: 1)
        #expect(mask.pixels.filter { $0 != 0 }.count == 4)
        #expect(mask.pixels[0] == 1 && mask.pixels[6] == 1 && mask.pixels[24] == 0)
        let resized = mask.resized(width: 10, height: 10)
        #expect(resized.pixels[0] == 1 && resized.pixels[99] == 0)
    }

    @Test func coloredStrokeCompletionOnlyGrowsConnectedSeededColor() {
        var image = solid(10, 2, (255, 255, 255))
        for x in [1, 2, 3, 7] {
            image.pixels[x * 4] = 10
            image.pixels[x * 4 + 1] = 30
            image.pixels[x * 4 + 2] = 180
        }
        image.pixels[4 * 4] = 0
        image.pixels[4 * 4 + 1] = 0
        image.pixels[4 * 4 + 2] = 0
        var pixels = [UInt8](repeating: 0, count: 20)
        pixels[1] = 1
        let grown = InkMask(width: 10, height: 2, pixels: pixels).extendingColoredStrokes(in: image)
        #expect(grown.pixels[1] == 1 && grown.pixels[2] == 1 && grown.pixels[3] == 1)
        #expect(grown.pixels[4] == 0) // black printed content
        #expect(grown.pixels[7] == 0) // disconnected colored content
    }

    @Test func coloredStrokeCompletionDoesNotFloodLargeRegions() {
        let image = solid(80, 80, (20, 30, 180))
        var pixels = [UInt8](repeating: 0, count: 80 * 80)
        pixels[40 * 80 + 40] = 1
        let grown = InkMask(width: 80, height: 80, pixels: pixels).extendingColoredStrokes(in: image)
        #expect(grown.pixels.filter { $0 != 0 }.count == 1)
    }

    @Test func backgroundRepairChangesOnlyMaskedPixels() {
        var image = solid(7, 7, (245, 240, 230))
        let center = 3 * 7 + 3
        image.pixels[center * 4] = 10
        image.pixels[center * 4 + 1] = 15
        image.pixels[center * 4 + 2] = 20
        let printedNeighbor = center - 1
        for c in 0..<3 { image.pixels[printedNeighbor * 4 + c] = 0 }
        var pixels = [UInt8](repeating: 0, count: 49)
        pixels[center] = 1
        let mask = InkMask(width: 7, height: 7, pixels: pixels)
        let result = BackgroundRepair.apply(to: image, mask: mask)
        #expect(result.pixels[center * 4] == 245)
        #expect(result.pixels[center * 4 + 1] == 240)
        #expect(result.pixels[center * 4 + 2] == 230)
        for i in 0..<49 where i != center {
            #expect(Array(result.pixels[(i * 4)..<(i * 4 + 4)]) == Array(image.pixels[(i * 4)..<(i * 4 + 4)]))
        }
        let empty = InkMask(width: 7, height: 7, pixels: [UInt8](repeating: 0, count: 49))
        #expect(BackgroundRepair.apply(to: image, mask: empty).pixels == image.pixels)
    }
}
