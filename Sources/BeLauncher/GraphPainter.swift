import SwiftUI
import BeLauncherCore

/// How the brain is drawn.
///
/// The first version of this was flat discs with a hairline stroke, and it looked like a diagram
/// in a settings pane rather than like anything anybody would want to look at. That was avoidable:
/// Believe already draws brains, in GetMaas and in Maasy and in BeMail, and they share one visual
/// language that was written down and then ignored here.
///
/// So this is that language, ported rather than invented:
///
/// - **A halo, then the disc, then the ring.** The halo is a radial gradient from the node's own
///   glow colour out to nothing. It is what turns a scatter of circles into a constellation, and
///   it is the single biggest difference between the two versions.
/// - **Weight is area, not colour.** `sqrt(weight)` so a node seen fifty times is bigger than one
///   seen five without being ten times bigger and eating the canvas.
/// - **Pointing at something dims everything it does not touch.** Unrelated nodes drop to 18 % and
///   their edges almost vanish, so the subgraph you are asking about is the only thing lit. This
///   is what makes a dense graph readable, and no amount of layout tuning replaces it.
/// - **Edges carry particles** where the relation is a flow — something that came out of something
///   else. A still graph says these things are connected; a moving one says which way.
enum GraphPainter {

    /// One node's colours, in the shape the other Believe brains use: a fill, a glow for the halo,
    /// and a brighter ring.
    struct Visual {
        let fill: Color
        let glow: Color
        let ring: Color
        let icon: String?
    }

    /// The palette. Believe blue and cyan lead, because they are the brand and because the two
    /// carry the two things that matter most here: what you did, and who you did it with.
    static func visual(for shape: GraphLayout.Node.Shape) -> Visual {
        switch shape {
        case .episode:
            Visual(fill: Color(red: 0.024, green: 0.714, blue: 0.831),
                   glow: Color(red: 0.024, green: 0.714, blue: 0.831).opacity(0.85),
                   ring: Color(red: 0.404, green: 0.910, blue: 0.976), icon: "✦")
        case .project:
            Visual(fill: Color(red: 0.220, green: 0.380, blue: 0.769),
                   glow: Color(red: 0.220, green: 0.380, blue: 0.769).opacity(0.60),
                   ring: Color(red: 0.620, green: 0.843, blue: 1.0), icon: "◆")
        case .person:
            Visual(fill: Color(red: 0.0, green: 0.6, blue: 1.0),
                   glow: Color(red: 0.0, green: 0.6, blue: 1.0).opacity(0.55),
                   ring: Color(red: 0.620, green: 0.843, blue: 1.0), icon: "●")
        case .company:
            Visual(fill: Color(red: 0.769, green: 0.157, blue: 0.831),
                   glow: Color(red: 0.769, green: 0.157, blue: 0.831).opacity(0.55),
                   ring: Color(red: 0.902, green: 0.612, blue: 0.941), icon: "▲")
        case .topic:
            Visual(fill: Color(red: 0.961, green: 0.706, blue: 0.329),
                   glow: Color(red: 0.961, green: 0.706, blue: 0.329).opacity(0.55),
                   ring: Color(red: 1.0, green: 0.824, blue: 0.478), icon: "◇")
        case .thing:
            Visual(fill: Color(red: 0.451, green: 0.478, blue: 0.545),
                   glow: Color(red: 0.451, green: 0.478, blue: 0.545).opacity(0.40),
                   ring: Color(red: 0.706, green: 0.729, blue: 0.784), icon: nil)
        }
    }

    /// How faded something unrelated gets. Not hidden: a graph that hides half of itself when the
    /// pointer moves is a graph nobody trusts.
    static let dimmed: Double = 0.18

    /// Who touches whom, so dimming knows what to keep lit.
    static func adjacency(_ lines: [GraphLayout.Line]) -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for line in lines {
            map[line.source, default: []].insert(line.target)
            map[line.target, default: []].insert(line.source)
        }
        return map
    }

    // MARK: - Edges

    static func drawLines(_ context: inout GraphicsContext, drawing: GraphLayout.Drawing,
                          focus: String?, neighbours: [String: Set<String>], phase: Double) {
        for line in drawing.lines {
            let lit = focus == nil || line.source == focus || line.target == focus
            var path = Path()
            path.move(to: CGPoint(x: line.fromX, y: line.fromY))
            path.addLine(to: CGPoint(x: line.toX, y: line.toY))

            context.stroke(
                path,
                with: .color(lit ? Color(red: 0.62, green: 0.84, blue: 1).opacity(0.55)
                                 : .white.opacity(0.04)),
                lineWidth: lit ? 1.6 * max(0.6, line.strength) : 0.8
            )

            // Particles only on the edges being looked at. Everywhere at once is a screensaver.
            guard lit, focus != nil else { continue }
            for index in 0..<2 {
                let travel = (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let x = line.fromX + (line.toX - line.fromX) * travel
                let y = line.fromY + (line.toY - line.fromY) * travel
                let dot = CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)
                context.fill(Path(ellipseIn: dot),
                             with: .color(Color(red: 0.62, green: 0.84, blue: 1).opacity(0.95)))
            }
        }
    }

    // MARK: - Nodes

    static func drawNodes(_ context: inout GraphicsContext, drawing: GraphLayout.Drawing,
                          selected: String?, compared: String?, hovered: String?,
                          neighbours: [String: Set<String>], labelled: Set<String>) {
        let focus = hovered ?? selected

        for node in drawing.nodes {
            let visual = visual(for: node.shape)
            let isFaded = focus != nil && node.id != focus
                && !(neighbours[focus!]?.contains(node.id) ?? false)
            let alpha = isFaded ? dimmed : 1
            let hot = node.id == focus
            let radius = node.radius

            // The halo. Drawn first and largest, so the discs sit inside their own light.
            let haloRadius = radius * (hot ? 4.5 : 3)
            let halo = CGRect(x: node.x - haloRadius, y: node.y - haloRadius,
                              width: haloRadius * 2, height: haloRadius * 2)
            context.fill(
                Path(ellipseIn: halo),
                with: .radialGradient(
                    Gradient(colors: [visual.glow.opacity(alpha), visual.glow.opacity(0)]),
                    center: CGPoint(x: node.x, y: node.y),
                    startRadius: radius * 0.4, endRadius: haloRadius
                )
            )

            let disc = CGRect(x: node.x - radius, y: node.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: disc), with: .color(visual.fill.opacity(alpha)))
            context.stroke(Path(ellipseIn: disc.insetBy(dx: -1.4, dy: -1.4)),
                           with: .color(visual.ring.opacity(alpha)),
                           lineWidth: hot ? 1.6 : 1)

            // A second, wider ring on the big ones: it reads as a pulse and it is how the eye
            // finds the anchors of a dense graph without any labels being on.
            if radius > 7 {
                context.stroke(Path(ellipseIn: disc.insetBy(dx: -radius * 0.8, dy: -radius * 0.8)),
                               with: .color(visual.ring.opacity(alpha * 0.35)), lineWidth: 0.8)
            }

            if node.id == selected || node.id == compared {
                context.stroke(
                    Path(ellipseIn: disc.insetBy(dx: -6, dy: -6)),
                    with: .color(node.id == selected ? visual.ring : .white),
                    style: StrokeStyle(lineWidth: 2, dash: node.id == compared ? [3, 3] : [])
                )
            }

            if let icon = visual.icon, radius > 6 {
                context.draw(Text(icon).font(.system(size: radius * 0.9)).foregroundColor(.white.opacity(alpha)),
                             at: CGPoint(x: node.x, y: node.y))
            }

            guard labelled.contains(node.id) || hot else { continue }
            context.draw(
                Text(node.label)
                    .font(.system(size: 10, weight: hot ? .semibold : .regular))
                    .foregroundColor(.white.opacity(isFaded ? dimmed : 0.92)),
                at: CGPoint(x: node.x, y: node.y + radius + 9)
            )
        }
    }
}
