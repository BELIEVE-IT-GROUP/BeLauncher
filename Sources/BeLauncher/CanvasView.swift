import SwiftUI
import AppKit
import BeLauncherCore

/// Drives one canvas: fills the blocks one at a time and keeps the person's edits.
///
/// Blocks are filled sequentially rather than all at once. A local model answering seven prompts in
/// parallel makes a Mac unusable for a minute, and the person can start reading and editing the
/// first block while the rest arrive — which is the difference between a workspace and a progress
/// bar.
@MainActor
@Observable
final class CanvasModel {
    private(set) var canvas: BeLauncherCore.Canvas
    private(set) var isFilling = false
    private(set) var filling: String?
    var status: String?

    private let definition: CanvasTemplate.Definition
    private let context: String
    private let run: @MainActor (String) async throws -> String
    private let perform: @MainActor (LauncherModel.Action) -> Void
    private let saveToBrain: @MainActor (BeLauncherCore.Canvas) -> Void
    /// Told what changed when someone rewrites a block. The strongest signal in the product: a
    /// person editing a draft is saying exactly what was wrong with it, without being asked.
    private let learn: @MainActor (String, String) -> Void
    private var task: Task<Void, Never>?

    init(definition: CanvasTemplate.Definition, brief: String, context: String = "",
         run: @escaping @MainActor (String) async throws -> String,
         perform: @escaping @MainActor (LauncherModel.Action) -> Void,
         saveToBrain: @escaping @MainActor (BeLauncherCore.Canvas) -> Void = { _ in },
         learn: @escaping @MainActor (String, String) -> Void = { _, _ in }) {
        self.definition = definition
        self.context = context
        self.run = run
        self.perform = perform
        self.saveToBrain = saveToBrain
        self.learn = learn
        self.canvas = CanvasTemplate.canvas(definition, brief: brief)
    }

    var progress: Double { canvas.progress }

    func fillAll() {
        guard !isFilling else { return }
        isFilling = true
        task = Task { @MainActor in
            defer { isFilling = false; filling = nil }
            for block in canvas.blocks where !block.isReady && block.kind != .action {
                if Task.isCancelled { return }
                filling = block.id
                await fill(block)
            }
            status = L("Ready. Edit whatever you want and run it when it is.")
        }
    }

    func regenerate(_ blockID: String) {
        guard let block = canvas.blocks.first(where: { $0.id == blockID }) else { return }
        task = Task { @MainActor in
            filling = blockID
            defer { filling = nil }
            // Regenerating is an explicit request, so it overrides the hand-edit guard that
            // protects blocks during a bulk fill.
            if let index = canvas.blocks.firstIndex(where: { $0.id == blockID }) {
                canvas.blocks[index].editedByHand = false
            }
            await fill(block)
        }
    }

    private func fill(_ block: BeLauncherCore.Canvas.Block) async {
        guard let prompt = CanvasTemplate.instruction(
            for: definition, blockTitle: block.title, brief: canvas.brief, context: context
        ) else { return }
        do {
            let answer = try await run(prompt)
            canvas.fill(block.id, body: answer)
        } catch {
            status = L("“%1$@” failed: %2$@", block.title, error.localizedDescription)
        }
    }

    func edit(_ blockID: String, body: String) {
        let before = canvas.blocks.first { $0.id == blockID }?.body ?? ""
        canvas.edit(blockID, body: body)
        if !before.isEmpty { learn(before, body) }
    }

    func cancel() {
        task?.cancel()
        isFilling = false
        filling = nil
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canvas.render(), forType: .string)
        status = "Copiado entero."
    }

    func copyBlock(_ blockID: String) {
        guard let block = canvas.blocks.first(where: { $0.id == blockID }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.body, forType: .string)
        status = L("“%@” copied.", block.title)
    }

    /// Runs the action blocks. Only these touch anything outside the canvas, and only after the
    /// person presses the button that says so.
    func runActions() {
        let actions = canvas.actions
        guard !actions.isEmpty else {
            status = L("This canvas has nothing to run: it is all text for you to use.")
            return
        }
        for action in actions { perform(action) }
        status = "Ejecutado: \(actions.count) paso(s)."
    }

    func save() {
        saveToBrain(canvas)
        status = L("Saved in your Brain.")
    }
}

/// The canvas on screen: blocks side by side, each editable, each runnable.
@MainActor
struct CanvasView: View {
    @Bindable var model: CanvasModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.canvas.blocks) { block in
                        BlockCard(block: block,
                                  isFilling: model.filling == block.id,
                                  edit: { model.edit(block.id, body: $0) },
                                  regenerate: { model.regenerate(block.id) },
                                  copy: { model.copyBlock(block.id) })
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 700)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.canvas.title).font(.system(size: 15, weight: .semibold))
                Text(model.canvas.brief.isEmpty ? L("No brief") : model.canvas.brief)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ProgressView(value: model.progress).frame(width: 110)
            if model.isFilling {
                Button("Parar") { model.cancel() }.controlSize(.small)
            } else {
                Button(L("Fill it all in")) { model.fillAll() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(L("Save in Brain")) { model.save() }
            Button(L("Copy it all")) { model.copyAll() }
            Button(L("Run the steps")) { model.runActions() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}

/// One block: what it is, what it says, and the two things worth doing to it.
@MainActor
private struct BlockCard: View {
    let block: BeLauncherCore.Canvas.Block
    let isFilling: Bool
    let edit: (String) -> Void
    let regenerate: () -> Void
    let copy: () -> Void

    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: block.kind.symbol)
                        .foregroundStyle(Theme.accent).frame(width: 15)
                    Text(block.title).font(.system(size: 12.5, weight: .semibold))
                    if block.editedByHand {
                        Text(L("edited by you"))
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.cyan.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    if isFilling {
                        ProgressView().controlSize(.small)
                    } else if block.isReady {
                        Button { copy() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(L("Copy this block"))
                        Button { regenerate() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Volver a generarlo")
                    }
                }

                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                    HStack {
                        Button(L("Save")) { edit(draft); editing = false }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Descartar") { editing = false }.controlSize(.small)
                    }
                } else if block.body.isEmpty {
                    Text(isFilling ? "Escribiendo…" : L("Empty. Fill it in or write it yourself."))
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture { draft = ""; editing = true }
                } else {
                    Text(block.body)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture { draft = block.body; editing = true }
                }
            }
            .padding(6)
        }
    }
}
