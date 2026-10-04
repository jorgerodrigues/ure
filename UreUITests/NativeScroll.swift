import XCTest

extension XCUIElement {
    @MainActor
    func scrollFullyIntoView(in window: XCUIElement) {
        let scrollView = window.scrollViews.containing(elementType, identifier: identifier)
            .firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<12 {
            if isHittable, scrollView.frame.insetBy(dx: 0, dy: 24).contains(frame) { return }
            if frame.midY > scrollView.frame.midY {
                scrollView.scroll(byDeltaX: 0, deltaY: -200)
            } else {
                scrollView.scroll(byDeltaX: 0, deltaY: 200)
            }
        }
    }
}
