// Migrated from the validated macOS lens prototype.
import AppKit

@MainActor
final class EyeLensView: NSView {
    var isReading = false { didSet { needsDisplay = true } }
    var hasTranslation = false { didSet { needsDisplay = true } }

    static func eyePath(in rect: CGRect) -> NSBezierPath {
        let left = CGPoint(x: rect.minX, y: rect.midY - 2)
        let right = CGPoint(x: rect.maxX, y: rect.midY + 2)
        let path = NSBezierPath()
        path.move(to: left)
        path.curve(to: right,
                   controlPoint1: CGPoint(x: rect.minX + rect.width * 0.23,
                                          y: rect.midY + rect.height * 0.65),
                   controlPoint2: CGPoint(x: rect.minX + rect.width * 0.73,
                                          y: rect.midY + rect.height * 0.65))
        path.curve(to: left,
                   controlPoint1: CGPoint(x: rect.minX + rect.width * 0.77,
                                          y: rect.midY - rect.height * 0.56),
                   controlPoint2: CGPoint(x: rect.minX + rect.width * 0.27,
                                          y: rect.midY - rect.height * 0.56))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let eyeRect = bounds.insetBy(dx: 3, dy: 3)
        let eye = Self.eyePath(in: eyeRect)

        // The eyelids mask the round iris; all accents stay outside the clear pupil.
        let center = CGPoint(x: eyeRect.midX, y: eyeRect.midY)
        let irisRadiusX = eyeRect.height * 0.75
        let irisRadiusY = eyeRect.height * 0.50
        let iris = CGRect(x: center.x - irisRadiusX, y: center.y - irisRadiusY,
                          width: irisRadiusX * 2, height: irisRadiusY * 2)
        let pupil = iris.insetBy(dx: irisRadiusX * 0.20, dy: irisRadiusY * 0.20)
        context.saveGState()
        eye.addClip()
        context.addEllipse(in: iris)
        context.addEllipse(in: pupil)
        context.clip(using: .evenOdd)
        context.setLineCap(.round)
        for index in 0..<96 {
            let phase = CGFloat(index)
            let angle = (phase / 96) * 2 * CGFloat.pi + sin(phase * 2.11) * 0.027
            let innerFactor = 0.79 + 0.03 * sin(phase * 1.7)
            let outerFactor = 0.94 + 0.045 * sin(phase * 1.31)
            let middleFactor = (innerFactor + outerFactor) / 2
            let bend = angle + 0.06 * sin(phase * 0.83)
            let hue = index.isMultiple(of: 4)
                ? NSColor(calibratedWhite: 0.80, alpha: 0.13)
                : NSColor(calibratedWhite: 0.96, alpha: 0.07)
            context.setStrokeColor(hue.cgColor)
            context.setLineWidth(index.isMultiple(of: 7) ? 0.9 : 0.55)
            context.move(to: CGPoint(x: center.x + cos(angle) * irisRadiusX * innerFactor,
                                     y: center.y + sin(angle) * irisRadiusY * innerFactor))
            context.addQuadCurve(to: CGPoint(x: center.x + cos(angle) * irisRadiusX * outerFactor,
                                             y: center.y + sin(angle) * irisRadiusY * outerFactor),
                                 control: CGPoint(x: center.x + cos(bend) * irisRadiusX * middleFactor,
                                                  y: center.y + sin(bend) * irisRadiusY * middleFactor))
            context.strokePath()
        }
        context.restoreGState()

        let pupilEdge = NSBezierPath(ovalIn: pupil)
        pupilEdge.lineWidth = hasTranslation ? 1.2 : 0.8
        if hasTranslation {
            NSColor.systemYellow.withAlphaComponent(0.72).setStroke()
        } else {
            NSColor(calibratedWhite: 0.92, alpha: 0.28).setStroke()
        }
        pupilEdge.stroke()
        let eyeBallDiameter = pupil.height * 0.56
        let eyeBallRadius = eyeBallDiameter / 2
        let eyeBallRect = CGRect(x: center.x - eyeBallRadius, y: center.y - eyeBallRadius,
                                 width: eyeBallDiameter, height: eyeBallDiameter)
        let eyeBall = NSBezierPath(ovalIn: eyeBallRect)
        // Fine, uneven iris fibers leave the central sight line open for the source text.
        context.saveGState()
        eyeBall.addClip()
        context.setLineCap(.round)
        for index in 0..<64 {
            let phase = CGFloat(index)
            let angle = phase * 2 * .pi / 64 + 0.035 * sin(phase * 2.37)
            let innerRadius = eyeBallRadius * (0.32 + 0.06 * sin(phase * 1.73))
            let outerRadius = eyeBallRadius * (0.78 + 0.16 * sin(phase * 0.91))
            let bend = angle + 0.09 * sin(phase * 1.19)
            let fiber = hasTranslation
                ? NSColor.systemYellow.withAlphaComponent(index.isMultiple(of: 5) ? 0.34 : 0.20)
                : NSColor(calibratedRed: 0.66, green: 0.77, blue: 0.84,
                          alpha: index.isMultiple(of: 5) ? 0.19 : 0.10)
            context.setStrokeColor(fiber.cgColor)
            context.setLineWidth(index.isMultiple(of: 7) ? 0.7 : 0.45)
            context.move(to: CGPoint(x: center.x + cos(angle) * innerRadius,
                                     y: center.y + sin(angle) * innerRadius))
            context.addQuadCurve(to: CGPoint(x: center.x + cos(angle) * outerRadius,
                                             y: center.y + sin(angle) * outerRadius),
                                 control: CGPoint(x: center.x + cos(bend) * eyeBallRadius * 0.60,
                                                  y: center.y + sin(bend) * eyeBallRadius * 0.60))
            context.strokePath()
        }
        context.restoreGState()
        let innerEye = NSBezierPath(ovalIn: eyeBallRect.insetBy(dx: eyeBallRadius * 0.73,
                                                                 dy: eyeBallRadius * 0.73))
        innerEye.lineWidth = 0.55
        (hasTranslation ? NSColor.systemYellow.withAlphaComponent(0.30)
                        : NSColor(calibratedWhite: 0.95, alpha: 0.16)).setStroke()
        innerEye.stroke()
        eyeBall.lineWidth = 0.7
        NSColor(calibratedWhite: 0.96, alpha: 0.16).setStroke()
        eyeBall.stroke()
        let lowerLid = NSBezierPath()
        lowerLid.move(to: CGPoint(x: center.x + irisRadiusX * 0.38,
                                  y: center.y - irisRadiusY * 0.70))
        lowerLid.curve(to: CGPoint(x: center.x + irisRadiusX * 0.86,
                                   y: center.y - irisRadiusY * 0.22),
                       controlPoint1: CGPoint(x: center.x + irisRadiusX * 0.56,
                                              y: center.y - irisRadiusY * 0.64),
                       controlPoint2: CGPoint(x: center.x + irisRadiusX * 0.75,
                                              y: center.y - irisRadiusY * 0.39))
        lowerLid.lineWidth = 0.75
        NSColor(calibratedWhite: 0.96, alpha: 0.22).setStroke()
        lowerLid.stroke()
        let upperLid = NSBezierPath()
        upperLid.move(to: CGPoint(x: center.x - irisRadiusX * 0.38,
                                  y: center.y + irisRadiusY * 0.70))
        upperLid.curve(to: CGPoint(x: center.x - irisRadiusX * 0.86,
                                   y: center.y + irisRadiusY * 0.22),
                       controlPoint1: CGPoint(x: center.x - irisRadiusX * 0.56,
                                              y: center.y + irisRadiusY * 0.64),
                       controlPoint2: CGPoint(x: center.x - irisRadiusX * 0.75,
                                              y: center.y + irisRadiusY * 0.39))
        upperLid.lineWidth = 0.75
        NSColor(calibratedWhite: 0.96, alpha: 0.22).setStroke()
        upperLid.stroke()
        // Fine folds shorten evenly toward the right tip, clear of the lower accent.
        context.saveGState()
        eye.addClip()
        for index in 0..<8 {
            let progress = CGFloat(index) / 7
            let lastFold = index == 7
            let end = CGPoint(x: eyeRect.maxX - CGFloat(index) - (lastFold ? 2 : 0),
                              y: eyeRect.midY + 2 - 0.7 * CGFloat(index))
            let start = CGPoint(x: center.x + irisRadiusX * (0.48 + 0.47 * progress),
                                y: lastFold ? end.y + 0.8
                                    : center.y + irisRadiusY * (0.74 - 0.90 * progress))
            let dx = end.x - start.x
            let dy = start.y - end.y
            let line = NSBezierPath()
            line.move(to: start)
            line.curve(to: end,
                       controlPoint1: CGPoint(x: start.x + dx * 0.32, y: start.y - dy * 0.08),
                       controlPoint2: CGPoint(x: end.x - dx * 0.22, y: end.y + dy * 0.23))
            line.lineWidth = lastFold ? 0.5 : 0.62
            line.lineCapStyle = .round
            let alpha = lastFold ? 0.06 : 0.22 - 0.013 * CGFloat(index)
            NSColor(calibratedWhite: 0.96, alpha: alpha).setStroke()
            line.stroke()
        }
        context.restoreGState()
        // The outer contour stays decorative; lock-on is shown at the clear center.
        eye.lineWidth = 1.8
        NSColor(calibratedWhite: 0.02, alpha: 0.02).setStroke()
        eye.stroke()
        eye.lineWidth = 0.8
        NSColor(calibratedWhite: 0.96, alpha: 0.02).setStroke()
        eye.stroke()
        let lampCenter = CGPoint(x: eyeRect.minX + 13,
                                 y: eyeRect.midY - 2)
        let breath = (1 + sin(uptime() * .pi * 2 / 2.2)) / 2
        NSColor.systemRed.withAlphaComponent(0.10 + 0.17 * breath).setFill()
        NSBezierPath(ovalIn: CGRect(x: lampCenter.x - 7, y: lampCenter.y - 7,
                                    width: 14, height: 14)).fill()
        NSColor.systemRed.withAlphaComponent(0.58 + 0.35 * breath).setFill()
        NSBezierPath(ovalIn: CGRect(x: lampCenter.x - 2.5, y: lampCenter.y - 2.5,
                                    width: 5, height: 5)).fill()
    }
}
