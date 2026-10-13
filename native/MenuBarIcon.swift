import AppKit

/// A small, resolution-independent version of Yike's two flowing shores.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let shore = NSBezierPath()
            shore.move(to: NSPoint(x: 3.5, y: 4.5))
            shore.curve(to: NSPoint(x: 3, y: 12),
                        controlPoint1: NSPoint(x: 1.5, y: 6.5),
                        controlPoint2: NSPoint(x: 1.6, y: 9.8))
            shore.curve(to: NSPoint(x: 11.7, y: 15.2),
                        controlPoint1: NSPoint(x: 4.6, y: 15.3),
                        controlPoint2: NSPoint(x: 9, y: 16.5))
            shore.curve(to: NSPoint(x: 11, y: 11.7),
                        controlPoint1: NSPoint(x: 14, y: 14),
                        controlPoint2: NSPoint(x: 13, y: 12.5))
            shore.curve(to: NSPoint(x: 3.5, y: 4.5),
                        controlPoint1: NSPoint(x: 7.5, y: 10.2),
                        controlPoint2: NSPoint(x: 3.8, y: 9.1))
            shore.close()
            shore.fill()

            let opposite = shore.copy() as! NSBezierPath
            opposite.transform(using: AffineTransform(m11: -1, m12: 0,
                                                     m21: 0, m22: -1,
                                                     tX: 18, tY: 18))
            opposite.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Yike"
        return image
    }
}
