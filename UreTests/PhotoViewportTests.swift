import AppKit
import CoreGraphics
import Testing

@testable import Ure

struct PhotoViewportTests {
    @Test
    func keyboardPanKeepsZoomAndStopsAtImageEdges() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let view = PhotoScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 180)
        view.layoutSubtreeIfNeeded()
        let assetID = UUID()
        view.update(image: image, assetID: assetID, request: PhotoZoomRequest())
        for _ in 0..<6 {
            view.update(image: image, assetID: assetID, request: PhotoZoomRequest(action: .in))
        }
        let scale = view.magnification
        let origin = view.contentView.bounds.origin
        #expect(view.acceptsFirstResponder)
        view.moveRight(nil)
        #expect(view.contentView.bounds.origin.x > origin.x)
        view.moveLeft(nil)
        #expect(abs(view.contentView.bounds.origin.x - origin.x) < 0.01)
        view.moveUp(nil)
        #expect(view.contentView.bounds.origin.y > origin.y)
        view.moveDown(nil)
        #expect(abs(view.contentView.bounds.origin.y - origin.y) < 0.01)
        for _ in 0..<100 { view.moveRight(nil) }
        let edge = view.contentView.bounds.origin
        view.moveRight(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.contentView.bounds.origin == edge)
        #expect(view.magnification == scale)
    }
}
