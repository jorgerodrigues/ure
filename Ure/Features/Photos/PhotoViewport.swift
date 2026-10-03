import AppKit
import SwiftUI

struct PhotoZoomRequest: Equatable {
    enum Action { case fit, `in`, out }
    let id = UUID()
    var action: Action = .fit
}

struct PhotoViewport: NSViewRepresentable {
    let image: CGImage
    let assetID: UUID
    let request: PhotoZoomRequest

    func makeNSView(context: Context) -> PhotoScrollView {
        PhotoScrollView()
    }

    func updateNSView(_ view: PhotoScrollView, context: Context) {
        view.update(image: image, assetID: assetID, request: request)
    }
}

final class PhotoScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var assetID: UUID?
    private var requestID: UUID?
    private var fitsImage = true

    init() {
        super.init(frame: .zero)
        contentView = PhotoClipView()
        documentView = imageView
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 8
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityLabel("Photo")
        setAccessibilityHelp(
            "Use arrow keys to pan. Use the Fit and Zoom controls to change scale.")
        imageView.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(pan)))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    override func moveLeft(_ sender: Any?) { panBy(x: -40, y: 0) }
    override func moveRight(_ sender: Any?) { panBy(x: 40, y: 0) }
    override func moveUp(_ sender: Any?) { panBy(x: 0, y: 40) }
    override func moveDown(_ sender: Any?) { panBy(x: 0, y: -40) }

    private func panBy(x: CGFloat, y: CGFloat) {
        fitsImage = false
        let origin = contentView.bounds.origin
        let proposed = NSRect(
            origin: NSPoint(x: origin.x + x / magnification, y: origin.y + y / magnification),
            size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }

    func update(image: CGImage, assetID: UUID, request: PhotoZoomRequest) {
        if self.assetID != assetID {
            self.assetID = assetID
            let size = NSSize(width: image.width, height: image.height)
            imageView.image = NSImage(cgImage: image, size: size)
            imageView.frame = NSRect(origin: .zero, size: size)
            fitsImage = true
        }
        guard requestID != request.id else { return }
        requestID = request.id
        switch request.action {
        case .fit:
            fitsImage = true
            fit()
        case .in: zoom(by: 1.25)
        case .out: zoom(by: 0.8)
        }
    }

    override func layout() {
        super.layout()
        if fitsImage { fit() }
    }

    override func magnify(with event: NSEvent) {
        fitsImage = false
        super.magnify(with: event)
    }

    private func fit() {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, contentSize.width > 0, contentSize.height > 0 else {
            return
        }
        let value = min(1, contentSize.width / size.width, contentSize.height / size.height)
        minMagnification = min(0.01, value)
        let bounded = value
        if abs(magnification - bounded) > 0.0001 {
            setMagnification(bounded, centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    private func zoom(by factor: CGFloat) {
        fitsImage = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(
            min(maxMagnification, max(minMagnification, magnification * factor)), centeredAt: center
        )
    }

    @objc private func pan(_ recognizer: NSPanGestureRecognizer) {
        let delta = recognizer.translation(in: imageView)
        let origin = contentView.bounds.origin
        contentView.scroll(to: NSPoint(x: origin.x - delta.x, y: origin.y - delta.y))
        reflectScrolledClipView(contentView)
        recognizer.setTranslation(.zero, in: imageView)
    }
}

private final class PhotoClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}
