import Foundation

/// Where every node goes, worked out the same way every time.
///
/// Written by hand rather than pulled from a graph library, and with no randomness anywhere. Both
/// decisions are about the same thing: a graph that lands in a different shape each time it opens
/// cannot be learned. People navigate their own memory by remembering that the client sits at the
/// top left and the auth work is the dense knot on the right, and a layout seeded from a random
/// number generator throws that away on every launch — the graph looks alive and is useless.
///
/// So the seed is a spiral over the ids sorted alphabetically, the relaxation is deterministic, and
/// shuffling the input changes nothing. Same brain, same picture.
///
/// Everything here is plain `Double`. No CoreGraphics, no view types: the layout is arithmetic and
/// has to be testable without a screen.
public enum GraphLayout {

    // MARK: - What goes in

    public struct Node: Sendable, Equatable, Identifiable {

        /// What a node is, which is also how it gets drawn.
        public enum Shape: String, Sendable, Equatable, CaseIterable, Codable {
            case episode
            case person
            case project
            case company
            case topic
            case thing

            public var label: String {
                switch self {
                case .episode: L("Episode")
                case .person: L("Person")
                case .project: L("Project")
                case .company: L("Company")
                case .topic: L("Subject")
                case .thing: L("Thing")
                }
            }
        }

        public let id: String
        public let label: String
        public let shape: Shape
        /// When it happened. The time axis is not a filter bolted on afterwards: this is a graph
        /// of things that happened, so being able to look at March matters as much as being able
        /// to look at a project.
        public let at: Date
        /// Relevance, 0 to 1. Drives size, drives what survives the budget.
        public let weight: Double

        public init(id: String, label: String, shape: Shape, at: Date, weight: Double = 0.5) {
            self.id = id
            self.label = label
            self.shape = shape
            self.at = at
            self.weight = min(max(weight, 0), 1)
        }
    }

    public struct Link: Sendable, Equatable {
        public let source: String
        public let target: String
        /// How hard it pulls. More shared evidence, shorter edge.
        public let strength: Double

        public init(source: String, target: String, strength: Double = 1) {
            self.source = source
            self.target = target
            self.strength = min(max(strength, 0.1), 3)
        }
    }

    // MARK: - What comes out

    public struct Placed: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let shape: Node.Shape
        public let at: Date
        public let weight: Double
        public let x: Double
        public let y: Double
        public let radius: Double

        public func distance(to px: Double, _ py: Double) -> Double {
            ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot()
        }
    }

    public struct Line: Sendable, Equatable {
        public let source: String
        public let target: String
        public let fromX: Double
        public let fromY: Double
        public let toX: Double
        public let toY: Double
        public let strength: Double
    }

    public struct Drawing: Sendable, Equatable {
        /// Painted in this order: heaviest last, so what matters is never buried.
        public let nodes: [Placed]
        public let lines: [Line]
        /// How many nodes did not fit in the budget.
        public let omitted: Int

        public init(nodes: [Placed], lines: [Line], omitted: Int) {
            self.nodes = nodes
            self.lines = lines
            self.omitted = omitted
        }

        public var isEmpty: Bool { nodes.isEmpty }

        public func node(_ id: String) -> Placed? { nodes.first { $0.id == id } }

        /// Said out loud rather than hidden, because a graph quietly showing two thirds of what it
        /// knows is worse than one that shows less and admits it.
        public var omittedNote: String? {
            guard omitted > 0 else { return nil }
            return L("%@ less relevant nodes are missing. Narrow the dates or raise the bar.", String(omitted))
        }
    }

    public enum Arrangement: String, Sendable, Equatable, CaseIterable {
        /// Shape by connection: what is worked on together ends up together.
        case force
        /// Shape by time: left to right, oldest to newest.
        case timeline

        public var label: String {
            switch self {
            case .force: L("By relation")
            case .timeline: L("By time")
            }
        }
    }

    public struct Options: Sendable, Equatable {
        public var width: Double
        public var height: Double
        public var arrangement: Arrangement
        /// How many nodes get drawn at most.
        ///
        /// Three hundred is where a picture stops being a map and becomes a hairball: past that
        /// nothing can be read, so drawing more is not showing more. Above the budget the layout
        /// keeps the heaviest and reports the rest as a number instead of pretending.
        public var budget: Int
        public var padding: Double

        public init(width: Double, height: Double, arrangement: Arrangement = .force,
                    budget: Int = 300, padding: Double = 34) {
            self.width = width
            self.height = height
            self.arrangement = arrangement
            self.budget = budget
            self.padding = padding
        }
    }

    // MARK: - Arranging

    /// Where every node goes.
    ///
    /// Pure arithmetic and deliberately not bound to any actor: three hundred nodes is ninety
    /// passes over every pair, and measured on the main actor that was half a second of frozen
    /// window for each letter typed into the filter. It belongs off the main actor, and the
    /// relaxation checks `Task.isCancelled` between passes so the one still running when the next
    /// letter arrives gives the core back instead of finishing a picture nobody will see.
    public static func arrange(nodes: [Node], links: [Link], options: Options) -> Drawing {
        let (kept, keptLinks, omitted) = thin(nodes: nodes, links: links, budget: options.budget)
        guard !kept.isEmpty else { return Drawing(nodes: [], lines: [], omitted: omitted) }

        // Sorted before anything touches a coordinate. Every position downstream is derived from
        // this order, so the picture cannot depend on the order the database happened to return.
        let ordered = kept.sorted { $0.id < $1.id }
        var index: [String: Int] = [:]
        for (offset, node) in ordered.enumerated() { index[node.id] = offset }

        // Sorted as well, and for a subtler reason than the nodes: floating point addition is not
        // associative, so accumulating the same pulls in a different order moves nodes by a
        // ten-thousandth of a point. Invisible on screen, but enough to make "the same brain draws
        // the same picture" false, and a guarantee that holds most of the time is not a guarantee.
        let edges = keptLinks.compactMap { link -> (Int, Int, Double)? in
            guard let source = index[link.source], let target = index[link.target],
                  source != target else { return nil }
            return (source, target, link.strength)
        }.sorted {
            $0.0 == $1.0 ? ($0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1) : $0.0 < $1.0
        }

        var points = seed(ordered)
        switch options.arrangement {
        case .force:
            relax(&points, edges: edges, count: ordered.count)
        case .timeline:
            spread(&points, nodes: ordered, edges: edges)
        }

        let radii = ordered.map { 6.0 + 12.0 * $0.weight }
        fit(&points, radii: radii, options: options)

        var placed: [Placed] = []
        for (offset, node) in ordered.enumerated() {
            placed.append(Placed(id: node.id, label: node.label, shape: node.shape, at: node.at,
                                 weight: node.weight, x: points[offset].0, y: points[offset].1,
                                 radius: radii[offset]))
        }

        let lines = edges.map { source, target, strength in
            Line(source: ordered[source].id, target: ordered[target].id,
                 fromX: points[source].0, fromY: points[source].1,
                 toX: points[target].0, toY: points[target].1, strength: strength)
        }

        return Drawing(nodes: placed.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight < $1.weight },
                       lines: lines, omitted: omitted)
    }

    /// Keeps what fits, drops the lightest, and says how many it dropped.
    public static func thin(nodes: [Node], links: [Link],
                            budget: Int) -> (nodes: [Node], links: [Link], omitted: Int) {
        guard nodes.count > budget, budget > 0 else { return (nodes, links, 0) }
        let kept = nodes
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
            .prefix(budget)
        let ids = Set(kept.map(\.id))
        return (Array(kept),
                links.filter { ids.contains($0.source) && ids.contains($0.target) },
                nodes.count - kept.count)
    }

    // MARK: - Seeding

    /// A golden-angle spiral over the sorted ids.
    ///
    /// The usual starting point is random positions, which is exactly what makes a force layout
    /// unstable. A spiral spreads the nodes evenly, gives the relaxation something sane to work
    /// from, and is the same spiral every time.
    static func seed(_ nodes: [Node]) -> [(Double, Double)] {
        let count = Double(nodes.count)
        return nodes.enumerated().map { offset, _ in
            let angle = Double(offset) * 2.399963229728653
            let radius = ((Double(offset) + 0.5) / count).squareRoot()
            return (radius * cos(angle), radius * sin(angle))
        }
    }

    /// A stable hash. `hashValue` is salted per process, so using it would move the graph on every
    /// launch — the one thing this file exists to prevent.
    static func stableFraction(_ text: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 10_000) / 10_000
    }

    // MARK: - Force relaxation

    /// Fruchterman-Reingold, cut down: repulsion between every pair, attraction along edges, a
    /// cooling cap on how far anything moves per pass, and a weak pull to the middle so
    /// disconnected islands do not drift off the canvas.
    static func relax(_ points: inout [(Double, Double)], edges: [(Int, Int, Double)], count: Int) {
        guard count > 1 else { return }
        let ideal = (1.0 / Double(count)).squareRoot()
        // Fewer passes as the graph grows: repulsion is quadratic, and a big graph settles into
        // its shape long before a small one does anyway.
        let passes = count <= 60 ? 220 : (count <= 200 ? 140 : 90)
        var temperature = 0.10

        for _ in 0..<passes {
            // Between passes, not inside them: the check is cheap but a graph at the budget runs
            // it forty-five thousand times per pass, and the point is to give the core back within
            // a few milliseconds, not within microseconds. What is on the points when this returns
            // is a half-relaxed picture, which is exactly right — the only caller that cancels is
            // one that has already decided to throw the answer away.
            if Task.isCancelled { return }
            var pushX = [Double](repeating: 0, count: count)
            var pushY = [Double](repeating: 0, count: count)

            for i in 0..<count {
                for j in (i + 1)..<count {
                    var dx = points[i].0 - points[j].0
                    var dy = points[i].1 - points[j].1
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < 0.0001 {
                        // Two nodes exactly on top of each other have no direction to separate
                        // along. Nudged apart deterministically rather than randomly.
                        dx = 0.0001 * Double(i - j)
                        dy = 0.0001
                        distance = 0.0001
                    }
                    let force = ideal * ideal / distance
                    pushX[i] += dx / distance * force
                    pushY[i] += dy / distance * force
                    pushX[j] -= dx / distance * force
                    pushY[j] -= dy / distance * force
                }
            }

            for (source, target, strength) in edges {
                let dx = points[source].0 - points[target].0
                let dy = points[source].1 - points[target].1
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.0001)
                let force = distance * distance / ideal * strength
                pushX[source] -= dx / distance * force
                pushY[source] -= dy / distance * force
                pushX[target] += dx / distance * force
                pushY[target] += dy / distance * force
            }

            for i in 0..<count {
                pushX[i] -= points[i].0 * 0.35
                pushY[i] -= points[i].1 * 0.35
                let length = max((pushX[i] * pushX[i] + pushY[i] * pushY[i]).squareRoot(), 0.0001)
                let step = min(length, temperature)
                points[i].0 += pushX[i] / length * step
                points[i].1 += pushY[i] / length * step
            }
            temperature *= 0.96
        }
    }

    // MARK: - Timeline

    /// Time on the horizontal, everything else resolved vertically.
    ///
    /// This is the arrangement the tesis asks for: a graph of what happened reads badly as a cloud
    /// of concepts and well as a river. March is a place you can point at.
    static func spread(_ points: inout [(Double, Double)], nodes: [Node],
                       edges: [(Int, Int, Double)]) {
        let times = nodes.map(\.at.timeIntervalSince1970)
        let earliest = times.min() ?? 0
        let latest = times.max() ?? 0
        let span = latest - earliest

        for (offset, node) in nodes.enumerated() {
            let fraction = span > 0 ? (times[offset] - earliest) / span : 0.5
            points[offset].0 = fraction * 2 - 1
            // Seeded from the id rather than from the spiral: down the column, a stable starting
            // spread beats a spiral that bunches everything near the centre.
            points[offset].1 = stableFraction(node.id) * 2 - 1
        }

        // Only vertical from here. Moving anything horizontally would be lying about when it
        // happened, which is the whole reason for this arrangement.
        let column = 0.08
        for _ in 0..<80 {
            if Task.isCancelled { return }
            var push = [Double](repeating: 0, count: nodes.count)
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count where abs(points[i].0 - points[j].0) < column {
                    var dy = points[i].1 - points[j].1
                    if abs(dy) < 0.0001 { dy = 0.0001 * Double(i - j) }
                    let force = 0.004 / max(abs(dy), 0.02)
                    push[i] += dy > 0 ? force : -force
                    push[j] -= dy > 0 ? force : -force
                }
            }
            for (source, target, strength) in edges {
                let dy = points[source].1 - points[target].1
                push[source] -= dy * 0.05 * strength
                push[target] += dy * 0.05 * strength
            }
            for i in 0..<nodes.count {
                points[i].1 = min(max(points[i].1 + max(min(push[i], 0.05), -0.05), -1), 1)
            }
        }
    }

    // MARK: - Fitting the canvas

    /// Scales the arrangement into the view, leaving room for the radius of every circle.
    ///
    /// The radius has to be in the sum: fitting the centres and then drawing circles around them
    /// clips the biggest node — which is always the most important one — against the edge.
    static func fit(_ points: inout [(Double, Double)], radii: [Double], options: Options) {
        guard !points.isEmpty else { return }
        let biggest = radii.max() ?? 0
        let inset = options.padding + biggest
        let usableWidth = max(options.width - inset * 2, 1)
        let usableHeight = max(options.height - inset * 2, 1)

        let minX = points.map(\.0).min() ?? 0
        let maxX = points.map(\.0).max() ?? 0
        let minY = points.map(\.1).min() ?? 0
        let maxY = points.map(\.1).max() ?? 0
        let spanX = maxX - minX
        let spanY = maxY - minY

        for index in points.indices {
            let fx = spanX > 0.0001 ? (points[index].0 - minX) / spanX : 0.5
            let fy = spanY > 0.0001 ? (points[index].1 - minY) / spanY : 0.5
            points[index] = (inset + fx * usableWidth, inset + fy * usableHeight)
        }
    }

    // MARK: - Pointing at things

    /// The node under a click, or nothing.
    ///
    /// A slack of a few points around the circle, because a node six points wide is not something
    /// anybody hits exactly, and a graph that ignores near misses feels broken rather than precise.
    public static func nearest(toX x: Double, y: Double, in drawing: Drawing,
                               slack: Double = 8) -> Placed? {
        var best: Placed?
        var bestDistance = Double.greatestFiniteMagnitude
        for node in drawing.nodes {
            let distance = node.distance(to: x, y)
            guard distance <= node.radius + slack, distance < bestDistance else { continue }
            best = node
            bestDistance = distance
        }
        return best
    }

    public enum Direction: Sendable, Equatable, CaseIterable {
        case left, right, up, down
    }

    /// Where the arrow keys go.
    ///
    /// Kept here rather than in the view because it is arithmetic and it is the part that decides
    /// whether the graph can be used without a mouse. Candidates are limited to a cone in the
    /// chosen direction, then ranked by distance, so pressing right walks across the graph instead
    /// of jumping to whatever happens to be closest overall.
    public static func step(from id: String, towards direction: Direction,
                            in drawing: Drawing) -> String? {
        guard let anchor = drawing.node(id) else { return drawing.nodes.last?.id }
        var best: String?
        var bestScore = Double.greatestFiniteMagnitude

        for node in drawing.nodes where node.id != id {
            let dx = node.x - anchor.x
            let dy = node.y - anchor.y
            let along: Double
            let across: Double
            switch direction {
            case .right: along = dx; across = abs(dy)
            case .left: along = -dx; across = abs(dy)
            case .down: along = dy; across = abs(dx)
            case .up: along = -dy; across = abs(dx)
            }
            guard along > 1, across <= along * 1.4 else { continue }
            // Distance along the axis plus a penalty for wandering off it: straight ahead wins
            // over slightly closer but sideways.
            let score = along + across * 1.6
            if score < bestScore {
                bestScore = score
                best = node.id
            }
        }
        return best
    }
}
