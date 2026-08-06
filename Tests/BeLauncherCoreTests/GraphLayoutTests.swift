import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Colocar el grafo")
struct GraphLayoutTests {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func node(_ id: String, weight: Double = 0.5, day: Double = 0,
                      shape: GraphLayout.Node.Shape = .project) -> GraphLayout.Node {
        GraphLayout.Node(id: id, label: id, shape: shape,
                         at: noon.addingTimeInterval(day * 86_400), weight: weight)
    }

    private func options(_ arrangement: GraphLayout.Arrangement = .force,
                         budget: Int = 300) -> GraphLayout.Options {
        GraphLayout.Options(width: 900, height: 620, arrangement: arrangement, budget: budget)
    }

    @Test("El mismo cerebro se dibuja siempre igual")
    func deterministic() {
        // Lo que hace navegable un grafo es que el cliente siga estando arriba a la izquierda la
        // próxima vez. Un layout con azar se ve vivo y no se puede aprender.
        let nodes = (0..<24).map { node("n\($0)", weight: Double($0 % 5) / 5) }
        let links = (0..<20).map { GraphLayout.Link(source: "n\($0)", target: "n\($0 + 3)") }
        let first = GraphLayout.arrange(nodes: nodes, links: links, options: options())
        let second = GraphLayout.arrange(nodes: nodes, links: links, options: options())
        #expect(first == second)
    }

    @Test("Barajar la entrada no mueve nada de sitio")
    func orderIndependent() {
        // La base devuelve las filas en el orden que le apetece. Si eso cambiara el dibujo, el
        // grafo saltaría entre aperturas sin que nadie hubiera tocado nada.
        let nodes = (0..<18).map { node("n\($0)", weight: Double($0 % 4) / 4) }
        let links = (0..<12).map { GraphLayout.Link(source: "n\($0)", target: "n\($0 + 2)") }
        let straight = GraphLayout.arrange(nodes: nodes, links: links, options: options())
        let shuffled = GraphLayout.arrange(nodes: nodes.reversed(), links: links.reversed(),
                                           options: options())
        #expect(straight == shuffled)
    }

    @Test("Nada se dibuja fuera del lienzo")
    func staysInside() {
        let nodes = (0..<40).map { node("n\($0)", weight: Double($0 % 10) / 10) }
        let drawing = GraphLayout.arrange(nodes: nodes, links: [], options: options())
        for placed in drawing.nodes {
            #expect(placed.x - placed.radius >= 0)
            #expect(placed.y - placed.radius >= 0)
            #expect(placed.x + placed.radius <= 900)
            #expect(placed.y + placed.radius <= 620)
        }
    }

    @Test("Dos nodos nunca acaban uno encima del otro")
    func noOverlap() {
        let nodes = (0..<30).map { node("n\($0)") }
        let drawing = GraphLayout.arrange(nodes: nodes, links: [], options: options())
        for (offset, one) in drawing.nodes.enumerated() {
            for other in drawing.nodes.dropFirst(offset + 1) {
                #expect(one.distance(to: other.x, other.y) > 2)
            }
        }
    }

    @Test("Lo que se trabajó junto queda junto")
    func linkedNodesCluster() {
        let nodes = ["a", "b", "c", "d", "e", "f"].map { node($0) }
        let links = [GraphLayout.Link(source: "a", target: "b"),
                     GraphLayout.Link(source: "b", target: "c"),
                     GraphLayout.Link(source: "a", target: "c")]
        let drawing = GraphLayout.arrange(nodes: nodes, links: links, options: options())

        let a = drawing.node("a")!
        let b = drawing.node("b")!
        let apart = ["d", "e", "f"].map { a.distance(to: drawing.node($0)!.x, drawing.node($0)!.y) }
        #expect(a.distance(to: b.x, b.y) < apart.min()!)
    }

    @Test("Por tiempo, marzo está a la izquierda de abril")
    func timelineRespectsTime() {
        // Es un grafo de cosas que pasaron, no de conceptos: poder mirar un mes vale tanto como
        // poder mirar un proyecto.
        let nodes = (0..<8).map { node("n\($0)", day: Double($0)) }
        let drawing = GraphLayout.arrange(nodes: nodes, links: [], options: options(.timeline))
        let byTime = drawing.nodes.sorted { $0.at < $1.at }
        for (earlier, later) in zip(byTime, byTime.dropFirst()) {
            #expect(earlier.x < later.x)
        }
    }

    @Test("Cuando hay miles, se queda con lo que importa y lo dice")
    func budgetFiltersInsteadOfDrawingAHairball() {
        let nodes = (0..<1_000).map { node("n\($0)", weight: Double($0) / 1_000) }
        let drawing = GraphLayout.arrange(nodes: nodes, links: [], options: options(budget: 120))
        #expect(drawing.nodes.count == 120)
        #expect(drawing.omitted == 880)
        #expect(drawing.omittedNote != nil)
        // Se queda con los pesados, no con los primeros que llegaron.
        #expect(drawing.nodes.allSatisfy { $0.weight >= 0.87 })
    }

    @Test("Con todo cabiendo no se omite nada ni se avisa de nada")
    func nothingOmittedWhenItFits() {
        let drawing = GraphLayout.arrange(nodes: (0..<10).map { node("n\($0)") }, links: [],
                                          options: options())
        #expect(drawing.omitted == 0)
        #expect(drawing.omittedNote == nil)
    }

    @Test("Un cerebro vacío no revienta, sale vacío")
    func emptyIsFine() {
        let drawing = GraphLayout.arrange(nodes: [], links: [], options: options())
        #expect(drawing.isEmpty)
        #expect(drawing.lines.isEmpty)
    }

    @Test("Un solo nodo se coloca sin dividir por cero")
    func singleNode() {
        let drawing = GraphLayout.arrange(nodes: [node("solo")], links: [], options: options())
        #expect(drawing.nodes.count == 1)
        #expect(drawing.nodes[0].x.isFinite)
        #expect(drawing.nodes[0].y.isFinite)
    }

    @Test("Un enlace a un nodo que no está no dibuja una línea al vacío")
    func danglingLinkIsDropped() {
        let drawing = GraphLayout.arrange(
            nodes: [node("a"), node("b")],
            links: [GraphLayout.Link(source: "a", target: "fantasma"),
                    GraphLayout.Link(source: "a", target: "b")],
            options: options())
        #expect(drawing.lines.count == 1)
    }

    @Test("Lo más relevante se pinta al final, para que no quede enterrado")
    func heaviestOnTop() {
        let drawing = GraphLayout.arrange(
            nodes: [node("chico", weight: 0.1), node("grande", weight: 0.9)],
            links: [], options: options())
        #expect(drawing.nodes.last?.id == "grande")
        #expect(drawing.nodes.last!.radius > drawing.nodes.first!.radius)
    }

    @Test("Cancelar deja el dibujo a medias en vez de terminar uno que nadie va a ver")
    func cancellable() async {
        // La ventana se congelaba medio segundo por cada tecla del filtro. Sacar el cálculo del
        // hilo principal no basta: si no atiende a la cancelación, cada letra deja un núcleo
        // ocupado terminando una imagen que ya no le sirve a nadie.
        let nodes = (0..<80).map { node("n\($0)", weight: Double($0 % 5) / 5) }
        let links = (0..<70).map { GraphLayout.Link(source: "n\($0)", target: "n\($0 + 5)") }
        let whole = GraphLayout.arrange(nodes: nodes, links: links, options: options())

        let abandoned = Task { () -> GraphLayout.Drawing in
            // Espera a que la prueba la cancele antes de empezar: así la comparación mide la
            // cancelación y no quién ganó la carrera.
            while !Task.isCancelled { await Task.yield() }
            return GraphLayout.arrange(nodes: nodes, links: links, options: options())
        }
        abandoned.cancel()
        let half = await abandoned.value

        #expect(half != whole)
        // Y sigue siendo un dibujo, no un destrozo: los mismos nodos, colocados donde iban.
        #expect(half.nodes.map(\.id).sorted() == whole.nodes.map(\.id).sorted())
    }

    @Test("Cancelar también corta el eje de tiempo")
    func cancellableTimeline() async {
        let nodes = (0..<80).map { node("n\($0)", day: Double($0 % 30)) }
        let whole = GraphLayout.arrange(nodes: nodes, links: [], options: options(.timeline))

        let abandoned = Task { () -> GraphLayout.Drawing in
            while !Task.isCancelled { await Task.yield() }
            return GraphLayout.arrange(nodes: nodes, links: [], options: options(.timeline))
        }
        abandoned.cancel()
        #expect(await abandoned.value != whole)
    }

    @Test("Pinchar cerca de un nodo lo elige; pinchar en el vacío no elige nada")
    func hitTesting() {
        let drawing = GraphLayout.arrange(nodes: (0..<6).map { node("n\($0)") }, links: [],
                                          options: options())
        let target = drawing.nodes[2]
        #expect(GraphLayout.nearest(toX: target.x + 2, y: target.y + 2, in: drawing)?.id == target.id)
        #expect(GraphLayout.nearest(toX: -500, y: -500, in: drawing) == nil)
    }

    @Test("La flecha derecha va al de la derecha, no al de arriba")
    func keyboardWalksTheGraph() {
        // Sin esto el grafo se mira pero no se usa: quien navega con teclado no tiene forma de
        // llegar a un nodo.
        let drawing = GraphLayout.Drawing(
            nodes: [
                GraphLayout.Placed(id: "centro", label: "centro", shape: .project, at: noon,
                                   weight: 0.5, x: 100, y: 100, radius: 8),
                GraphLayout.Placed(id: "derecha", label: "derecha", shape: .project, at: noon,
                                   weight: 0.5, x: 220, y: 108, radius: 8),
                GraphLayout.Placed(id: "arriba", label: "arriba", shape: .project, at: noon,
                                   weight: 0.5, x: 104, y: 20, radius: 8),
            ], lines: [], omitted: 0)

        #expect(GraphLayout.step(from: "centro", towards: .right, in: drawing) == "derecha")
        #expect(GraphLayout.step(from: "centro", towards: .up, in: drawing) == "arriba")
        #expect(GraphLayout.step(from: "derecha", towards: .right, in: drawing) == nil)
    }
}
