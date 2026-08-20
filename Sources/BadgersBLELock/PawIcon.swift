import AppKit

/// The menu bar glyph: a honey badger's front paw — four toes under four
/// detached claws, over a broad teardrop pad. Drawn rather than shipped as an
/// asset so it stays crisp at any status bar height.
///
/// Colour carries the state, since that is readable at a glance in a way a
/// change of silhouette is not: green when your phone is present, red while it
/// is missing and a lock is pending, amber when it is missing but you unlocked
/// anyway, grey and slashed when monitoring is off.
enum PawIcon {
    enum State {
        /// Phone missing — the lock countdown is running, or has already fired.
        case pending
        /// Phone present, nothing to do.
        case present
        /// You unlocked while the phone was away, so locking is paused until it
        /// comes back. Not the same as off — this one re-arms itself.
        case suspended
        /// Monitoring switched off.
        case disabled

        /// System colours, so they stay legible against a light or dark menu bar
        /// and follow the accessibility "increase contrast" setting.
        var tint: NSColor {
            switch self {
            case .pending:   return .systemRed
            case .present:   return .systemGreen
            case .suspended: return .systemOrange
            case .disabled:  return .systemGray
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .pending:   return "Phone away, lock pending"
            case .present:   return "Phone present"
            case .suspended: return "Phone away, locking paused until it returns"
            case .disabled:  return "Monitoring off"
            }
        }
    }

    /// Fills the paw into `rect` of the current context. Exposed so the app icon
    /// generator can draw the same geometry in its own colours.
    static func draw(in rect: NSRect, colour: NSColor, slashed: Bool = false) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.concatenate(fit(into: rect))

        colour.setFill()
        pad.fill()
        for toe in toes {
            toeShape(toe).fill()
            claw(toe).fill()
        }
        if slashed { strikeThrough(ctx, colour: colour) }

        ctx.restoreGState()
    }

    static func image(for state: State, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Colours are resolved inside the handler so the dynamic system ones
            // pick up the appearance in force at draw time, not at build time.
            draw(in: rect, colour: state.tint, slashed: state == .disabled)
            return true
        }
        // Not a template image: templates are recoloured to a flat black or white
        // by the status bar, which would throw away the state colour.
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    // MARK: - Geometry
    //
    // Everything hangs off one circle centred below the paw: the toes sit on it
    // and the claws sit further out along the same radials, which is what keeps
    // the fan even. Units are arbitrary and fitted to the requested size.

    private static let hub = CGPoint(x: 0, y: 0)
    private static let toeOrbit: CGFloat = 6.7
    private static let toeRX: CGFloat = 1.32
    private static let toeRY: CGFloat = 1.95
    /// Claws are separate marks, as on a real print — the toe pads and the claws
    /// touch the ground at different places.
    private static let clawGap: CGFloat = 0.55
    private static let clawLength: CGFloat = 3.15
    private static let clawWidth: CGFloat = 0.55
    /// How much of the fan's spread each claw takes on as rotation. At 1 every
    /// claw points straight out along its own radial and the outer pair end up
    /// nearly horizontal; near 0 they stand parallel. Held well under half so
    /// they read as a rake of upright spikes, which survives 18 points intact.
    private static let clawAngle: CGFloat = 0.45

    private struct Toe {
        /// Degrees from straight up; the paw is symmetric about 0.
        let spread: CGFloat
        var radians: CGFloat { spread * .pi / 180 }
        var center: CGPoint {
            CGPoint(x: hub.x + toeOrbit * sin(radians), y: hub.y + toeOrbit * cos(radians))
        }
        /// Where the claw sits is radial; how far it leans is not. Rotating a
        /// claw by its full share of the spread is what sends the outer pair off
        /// sideways like whiskers.
        var clawSpread: CGFloat { spread * clawAngle }
    }

    /// Four toes, matching a badger print's forefoot as it actually marks: the
    /// fifth is there on the animal but barely registers.
    private static let toes = [-38, -13, 13, 38].map { Toe(spread: CGFloat($0)) }

    /// Broad at the top and tapering to a blunt heel — the pad carries most of
    /// the weight of the silhouette, but stays shallow enough not to swallow the
    /// toes at 18 points. Four smooth segments, so the outline has no cusps.
    private static let pad: NSBezierPath = {
        let halfWidth: CGFloat = 4.45
        let top = toeOrbit - toeRY - 1.15            // clear of the toes
        let heel: CGFloat = -4.9
        let waistY: CGFloat = 0.35                    // height of the widest point
        let shoulder: CGFloat = 0.68                 // tangent length across the top
        let taper: CGFloat = 0.42                    // ...and into the heel

        let p = NSBezierPath()
        p.move(to: CGPoint(x: 0, y: top))
        p.curve(to: CGPoint(x: halfWidth, y: waistY),
                controlPoint1: CGPoint(x: halfWidth * shoulder, y: top),
                controlPoint2: CGPoint(x: halfWidth, y: waistY + (top - waistY) * shoulder))
        p.curve(to: CGPoint(x: 0, y: heel),
                controlPoint1: CGPoint(x: halfWidth, y: heel + (waistY - heel) * 0.42),
                controlPoint2: CGPoint(x: halfWidth * taper, y: heel))
        p.curve(to: CGPoint(x: -halfWidth, y: waistY),
                controlPoint1: CGPoint(x: -halfWidth * taper, y: heel),
                controlPoint2: CGPoint(x: -halfWidth, y: heel + (waistY - heel) * 0.42))
        p.curve(to: CGPoint(x: 0, y: top),
                controlPoint1: CGPoint(x: -halfWidth, y: waistY + (top - waistY) * shoulder),
                controlPoint2: CGPoint(x: -halfWidth * shoulder, y: top))
        p.close()
        return p
    }()

    private static func toeShape(_ toe: Toe) -> NSBezierPath {
        let oval = NSBezierPath(ovalIn: CGRect(x: -toeRX, y: -toeRY,
                                               width: toeRX * 2, height: toeRY * 2))
        var t = AffineTransform(translationByX: toe.center.x, byY: toe.center.y)
        t.rotate(byDegrees: -toe.spread)
        oval.transform(using: t)
        return oval
    }

    /// A straight tapered spike, identical for every toe — rotation is the only
    /// thing that differs between them. Bowing the claw sideways *and* rotating
    /// it compounds the two, and the claws end up pointing every which way.
    private static func claw(_ toe: Toe) -> NSBezierPath {
        let w = clawWidth, length = clawLength
        let p = NSBezierPath()
        p.move(to: CGPoint(x: -w, y: 0))
        p.curve(to: CGPoint(x: 0, y: length),
                controlPoint1: CGPoint(x: -w, y: length * 0.5),
                controlPoint2: CGPoint(x: -w * 0.3, y: length * 0.85))
        p.curve(to: CGPoint(x: w, y: 0),
                controlPoint1: CGPoint(x: w * 0.55, y: length * 0.8),
                controlPoint2: CGPoint(x: w, y: length * 0.45))
        // Rounded base, so the claw looks planted rather than snapped off.
        p.curve(to: CGPoint(x: -w, y: 0),
                controlPoint1: CGPoint(x: w * 0.6, y: -w),
                controlPoint2: CGPoint(x: -w * 0.6, y: -w))
        p.close()

        // Positioned on its own radial, but leaning only a fraction of it.
        let base = toeOrbit + toeRY + clawGap
        var t = AffineTransform(translationByX: hub.x + base * sin(toe.radians),
                                byY: hub.y + base * cos(toe.radians))
        t.rotate(byDegrees: -toe.clawSpread)
        p.transform(using: t)
        return p
    }

    /// The "off" slash: a clear gap punched through the paw with the bar sitting
    /// inside it, so the line stays legible over the fill.
    private static func strikeThrough(_ ctx: CGContext, colour: NSColor) {
        let b = contentBounds.insetBy(dx: 1.0, dy: 1.0)
        let bar = NSBezierPath()
        bar.move(to: CGPoint(x: b.minX, y: b.minY))
        bar.line(to: CGPoint(x: b.maxX, y: b.maxY))
        bar.lineCapStyle = .round

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        bar.lineWidth = 2.2
        bar.stroke()
        ctx.restoreGState()

        bar.lineWidth = 1.25
        colour.setStroke()
        bar.stroke()
    }

    // MARK: - Fitting

    private static let contentBounds: CGRect = {
        var box = pad.bounds
        for toe in toes { box = box.union(toeShape(toe).bounds).union(claw(toe).bounds) }
        return box
    }()

    private static func fit(into rect: NSRect) -> CGAffineTransform {
        // A hair of inset: the status bar crowds the glyph otherwise.
        let target = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.03)
        let scale = min(target.width / contentBounds.width, target.height / contentBounds.height)
        return CGAffineTransform(translationX: target.midX, y: target.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -contentBounds.midX, y: -contentBounds.midY)
    }
}
