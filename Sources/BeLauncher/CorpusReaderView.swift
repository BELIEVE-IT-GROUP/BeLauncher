import SwiftUI
import AppKit
import BeLauncherCore

/// Reading and correcting the corpus without leaving the launcher.
///
/// The folder is plain Markdown and could be opened in any editor. That is the point of the
/// format, and it is not an invitation to go elsewhere: a brain you have to open another app to
/// read stops being a product and becomes a background index, and the person ends up living in the
/// other app. So the reader is here, one shortcut away, and what it does that a text editor cannot
/// is make the difference between what the machine deduced and what you wrote visible at a glance.
@MainActor
@Observable
final class CorpusReaderModel {
    private let folder: CorpusFolder

    var query = ""
    var kind: CorpusDocument.Kind?
    var selectedID: String?
    var isEditing = false
    var draft = ""
    var status: String?
    private(set) var documents: [CorpusDocument] = []

    init(folder: CorpusFolder, selecting id: String? = nil) {
        self.folder = folder
        self.selectedID = id
        reload()
    }

    func reload() {
        documents = folder.documents()
        if selectedID == nil || !documents.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    /// What the search finds, newest first.
    ///
    /// Words first, fuzzy second. Somebody looking for an episode types a word that was in it, and
    /// a fuzzy matcher that also accepts scattered letters would bury that exact hit under noise.
    var results: [CorpusDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = documents.filter { kind == nil || $0.kind == kind }
        guard !trimmed.isEmpty else { return pool }
        let needle = Identity.fold(trimmed)
        return pool.filter { document in
            Identity.fold(document.title).contains(needle)
                || Identity.fold(document.body).contains(needle)
                || Fuzzy.match(query: trimmed, candidate: document.title) != nil
        }
    }

    var selected: CorpusDocument? {
        documents.first { $0.id == selectedID }
    }

    func select(_ id: String) {
        guard !isEditing else { return }
        selectedID = id
        status = nil
    }

    /// Follows a `[[link]]` to whatever answers to that name.
    func follow(_ name: String) {
        let wanted = Identity.fold(name)
        guard let target = documents.first(where: { Identity.fold($0.title) == wanted })
                ?? documents.first(where: { $0.links.contains(name) && $0.id != selectedID })
        else {
            status = L("“%@” has no entry of its own yet.", name)
            return
        }
        select(target.id)
    }

    func beginEditing() {
        guard let selected else { return }
        draft = selected.body
        isEditing = true
        status = nil
    }

    func cancelEditing() {
        isEditing = false
        draft = ""
    }

    func save() {
        guard let selected else { return }
        do {
            let edited = try folder.saveHandEdit(selected, body: draft)
            isEditing = false
            reload()
            selectedID = edited.id
            status = L("Saved. From now on this file is yours: the machine will not rewrite it.")
        } catch {
            status = L("Could not save: %@", error.localizedDescription)
        }
    }

    func revealInFinder() {
        guard let selected, let path = folder.existingPath(for: selected.id, kind: selected.kind) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

@MainActor
struct CorpusReaderView: View {
    @Bindable var model: CorpusReaderModel

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
            document
                .frame(minWidth: 380)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search your memory"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Picker("", selection: $model.kind) {
                Text(L("Everything")).tag(CorpusDocument.Kind?.none)
                ForEach(CorpusDocument.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(CorpusDocument.Kind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if model.results.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.results) { document in
                            row(document)
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Mascot(height: 74)
            Text(model.documents.isEmpty
                 ? L("Nothing here yet. As soon as the brain captures a stretch of work, it shows up.")
                 : L("Nothing matches “%@”.", model.query))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ document: CorpusDocument) -> some View {
        let isSelected = document.id == model.selectedID
        return Button {
            model.select(document.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(document.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if document.corrections.pinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9)).foregroundStyle(Theme.cyan)
                    }
                    if document.corrections.editedByHand {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9)).foregroundStyle(Theme.cyan)
                    }
                }
                Text("\(document.kind.label) · \(stamp(document.occurredAt))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The document

    @ViewBuilder
    private var document: some View {
        if let selected = model.selected {
            VStack(spacing: 0) {
                header(selected)
                Divider()
                if model.isEditing {
                    editor
                } else {
                    ScrollView {
                        MarkdownBody(text: selected.body, follow: model.follow)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let status = model.status {
                    Divider()
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text(L("Pick something from the list")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ document: CorpusDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(document.title)
                    .font(.system(size: 16, weight: .semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if model.isEditing {
                    Button("Descartar") { model.cancelEditing() }.controlSize(.small)
                    Button(L("Save")) { model.save() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button(L("Edit")) { model.beginEditing() }
                        .controlSize(.small)
                        .keyboardShortcut("e", modifiers: .command)
                    Button {
                        model.revealInFinder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Show the file in the Finder. It is yours and it is an ordinary .md."))
                }
            }

            HStack(spacing: 8) {
                Tag(text: document.kind.label, tone: .neutral)
                Tag(text: stamp(document.occurredAt), tone: .neutral)
                if document.corrections.editedByHand {
                    // La marca que importa: mientras esté, la máquina no toca este archivo.
                    Tag(text: L("written by you"), tone: .mine)
                }
                if document.corrections.pinned { Tag(text: "importante", tone: .mine) }
                if document.corrections.hidden { Tag(text: L("outside the graph"), tone: .muted) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.draft)
                .font(.system(size: 13, design: .monospaced))
                .padding(12)
            Divider()
            Text(L("What you write here outranks whatever the machine worked out, and never gets overwritten."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
        }
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }
}

/// A small label. Not a general component: three tones is everything this window needs.
struct Tag: View {
    enum Tone { case neutral, mine, muted }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: tone == .mine ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(tone == .muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.08)
        case .mine: Theme.cyan.opacity(0.22)
        case .muted: Color.primary.opacity(0.04)
        }
    }
}

/// Just enough Markdown to read a corpus file properly.
///
/// Headings, bullets and `[[links]]`, which is the whole vocabulary these files use. A full
/// Markdown renderer would be a lot of code for content we write ourselves, and `Text(.init(…))`
/// renders neither headings nor lists — a corpus file through it comes out as one grey paragraph,
/// which is exactly the wall of text the reader exists to avoid.
struct MarkdownBody: View {
    let text: String
    let follow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, raw in
                line(String(raw))
            }
        }
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        if raw.hasPrefix("# ") {
            Text(String(raw.dropFirst(2)))
                .font(.system(size: 19, weight: .semibold))
                .padding(.bottom, 2)
        } else if raw.hasPrefix("## ") {
            Text(String(raw.dropFirst(3)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 10)
        } else if raw.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Theme.cyan.opacity(0.7)).frame(width: 4, height: 4).padding(.top, 7)
                inline(String(raw.dropFirst(2)))
            }
        } else if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else {
            inline(raw)
        }
    }

    /// Splits a line into text and `[[links]]`, so a link is a button rather than punctuation.
    @ViewBuilder
    private func inline(_ raw: String) -> some View {
        let pieces = MarkdownBody.pieces(of: raw)
        if pieces.contains(where: \.isLink) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    if piece.isLink {
                        Button(piece.text) { follow(piece.text) }
                            .buttonStyle(.link)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text(piece.text).font(.system(size: 13))
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            Text(raw).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    struct Piece {
        let text: String
        let isLink: Bool
    }

    static func pieces(of line: String) -> [Piece] {
        var result: [Piece] = []
        var rest = Substring(line)
        while let open = rest.range(of: "[["),
              let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let before = String(rest[rest.startIndex..<open.lowerBound])
            if !before.isEmpty { result.append(Piece(text: before, isLink: false)) }
            result.append(Piece(text: String(rest[open.upperBound..<close.lowerBound]), isLink: true))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { result.append(Piece(text: String(rest), isLink: false)) }
        return result
    }
}
