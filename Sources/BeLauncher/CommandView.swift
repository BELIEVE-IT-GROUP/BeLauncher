import QuickLookThumbnailing
import AppKit
import SwiftUI
import BeLauncherCore

@MainActor
struct CommandView: View {
    @Bindable var model: LauncherModel
    let openSettings: () -> Void
    let newNote: () -> Void
    let recordVoice: () -> Void
    let dictate: () -> Void

    @FocusState private var focus: Field?

    enum Field: Hashable { case search, actions }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if showsBody {
                Divider().overlay(.white.opacity(0.08))
                if isBrainLaunchpadWithClipboard {
                    emptyLaunchpad
                        .frame(height: emptyLaunchpadHeight)
                } else if isCarousel {
                    // Clipboard gets the full width: the cards are the point, and a 430pt column
                    // would fit two and a half of them. The preview keeps its place, just below
                    // rather than beside.
                    VStack(spacing: 0) {
                        ClipboardCarousel(model: model)
                        if let detail = model.detail {
                            Divider().overlay(.white.opacity(0.07))
                            DetailPane(detail: detail)
                                .frame(height: 172)
                        }
                    }
                } else {
                HStack(spacing: 0) {
                    stateContent(model.state)
                        .frame(maxWidth: model.detail == nil ? .infinity : Theme.listWidth,
                               alignment: .topLeading)
                    if let mission = model.mission {
                        Divider().overlay(.white.opacity(0.07))
                        MissionPane(mission: mission,
                                    approve: { model.approveMission() },
                                    cancel: { model.cancelMission() })
                    } else if model.aiState != .idle {
                        Divider().overlay(.white.opacity(0.07))
                        AIPane(state: model.aiState, dismiss: { model.clearAI() })
                    } else if let detail = model.detail {
                        Divider().overlay(.white.opacity(0.07))
                        DetailPane(detail: detail)
                    }
                }
                .frame(height: bodyHeight)
                }
            }
            Divider().overlay(.white.opacity(0.08))
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(GlassSurface())
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(GlassEdge())
        .overlay(alignment: .bottomTrailing) {
            if model.isActionPanelOpen {
                ActionPanelView(model: model, focus: $focus)
                    .padding(.trailing, 10)
                    .padding(.bottom, 42)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .padding(Theme.shadowPadding)
        .onAppear { focusSearchSoon() }
        .onChange(of: model.focusToken) { focusSearchSoon() }
        .onChange(of: model.state) {
            if !model.isActionPanelOpen { focusSearchSoon() }
        }
        .onChange(of: model.isActionPanelOpen) {
            model.isActionPanelOpen ? focusActionsSoon() : focusSearchSoon()
        }
        .animation(.easeOut(duration: 0.12), value: model.results)
        .animation(.easeOut(duration: 0.12), value: model.state)
        .animation(.easeOut(duration: 0.1), value: model.isActionPanelOpen)
    }

    private func focusSearchSoon() {
        focus = .search
        DispatchQueue.main.async { focus = .search }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .search }
    }

    private func focusActionsSoon() {
        focus = .actions
        DispatchQueue.main.async { focus = .actions }
    }

    /// Cards only where they beat a list: clipboard history, which is the one thing here you
    /// recognise by looking rather than by reading.
    ///
    /// Keyed on what is on screen, not on which key opened the window. Tying it to ⌥C meant the
    /// same clipboard items were cards through one door and a list through the other, and the
    /// person who opened with ⇧⌘Espacio — which is most of the time — never saw the cards at all
    /// and reasonably concluded they were not there.
    private var isCarousel: Bool {
        guard model.mission == nil, model.aiState == .idle, !model.results.isEmpty else {
            return false
        }
        return model.results.allSatisfy { $0.kind == .clipboard }
    }

    private var isBrainLaunchpadWithClipboard: Bool {
        guard case .empty = model.state,
              model.mode != .clipboard,
              model.mission == nil,
              model.aiState == .idle else { return false }
        return !brainEntries.isEmpty && !clipEntries.isEmpty
    }

    private var brainEntries: [(index: Int, result: SearchResult)] {
        Array(model.results.enumerated()).compactMap { index, result in
            result.id.hasPrefix("brain-") ? (index, result) : nil
        }
    }

    private var clipEntries: [(index: Int, result: SearchResult)] {
        Array(model.results.enumerated()).compactMap { index, result in
            result.kind == .clipboard ? (index, result) : nil
        }
    }

    private var showsBody: Bool {
        switch model.state {
        case .results, .noMatch, .loading, .failed: true
        case .empty: !model.results.isEmpty
        }
    }

    /// The list drives the height, so showing a detail never makes the window jump.
    /// How tall the list is allowed to be.
    ///
    /// There was no ceiling, so the panel simply grew with the number of rows. Thirteen results
    /// asked for around 800 points, the window is anchored a sixth of the way down the screen, and
    /// what did not fit went off the top: the first row ended up drawn over the search field with
    /// the text showing through it, and typing became impossible because the field was underneath
    /// its own results.
    ///
    /// Measured against the screen the panel is actually on, and it scrolls inside whatever is
    /// left. A launcher that covers its own input is worse than one that shows six results.
    private var maximumBodyHeight: CGFloat {
        let available = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                         ?? NSScreen.main)?.visibleFrame.height ?? 900
        // The panel sits with its top edge at 16 % from the top, and the field and footer take
        // their own space above and below the list.
        let below = available * 0.84 - Theme.searchHeight - 46
        return max(Theme.rowHeight * 3, below)
    }

    private var bodyHeight: CGFloat? {
        switch model.state {
        case .results, .empty:
            let rows = min(model.results.count, SearchEngine.resultLimit)
            let header: CGFloat = (model.state == .empty && !model.results.isEmpty) ? 24 : 0
            let wanted = CGFloat(rows) * (Theme.rowHeight + 2) + 16 + header
            return min(wanted, maximumBodyHeight)
        case .loading, .noMatch, .failed:
            return nil
        }
    }

    private var emptyLaunchpadHeight: CGFloat {
        let quickRows = CGFloat(min(brainEntries.count, SearchEngine.resultLimit))
        let quick = quickRows * (Theme.rowHeight + 2) + 34
        let carousel = ClipboardCarousel.cardHeight + 54
        return min(quick + carousel, maximumBodyHeight)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 13) {
            AppIconView(side: 26)

            CommandSearchField(
                text: $model.query,
                placeholder: L("Search, calculate, convert, or type what you want to do"),
                focusSeed: model.focusToken,
                wantsFocus: !model.isActionPanelOpen,
                onSubmit: { model.handle(.enter) }
            )
            .frame(height: 28)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    focus = .search
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("Clear"))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.searchHeight)
    }

    // MARK: - States

    @ViewBuilder
    private func stateContent(_ state: LauncherModel.State) -> some View {
        switch state {
        case .loading:
            message {
                ProgressView().controlSize(.small)
                Text(L("Looking through your apps…"))
            }

        case .empty, .results:
            resultList

        case .noMatch:
            message {
                Mascot(height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Nothing for “%@”", model.query)).fontWeight(.medium)
                    // The empty state is the one place everybody lands, so it is the one place
                    // worth spending on teaching what can be typed.
                    // The examples are translated with the copy, because they have to be typeable: every
                    // one of these strings is a phrase the intent tables in `Phrases` recognise.
                    Text(L("Try: **2+2** calculates · **10 km to mi** converts · **f report** finds files · **focus** starts a block of work · **what did we decide about …** asks your brain."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .failed(let reason):
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("BeLauncher could not read its own database")).fontWeight(.medium)
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L("Try again")) { model.retry() }.controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func message<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 11) { content(); Spacer() }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .font(.system(size: 13))
    }

    /// The results, scrolling inside whatever height the panel allows.
    ///
    /// This used to be a bare `VStack` inside a `.frame(height:)`. That is not a clamp: a stack
    /// whose rows ask for more room than the frame gives them does not scroll and does not clip —
    /// it overflows, centred, so half the excess spills out of the *top*. With thirteen results the
    /// first rows landed on the search field and drew over it, the typed text showing through from
    /// underneath, and typing became impossible because the field was buried under its own results.
    ///
    /// A `ScrollView` is what makes the height a real ceiling. The reader keeps the selected row in
    /// view, so arrow keys still walk the whole list once it stops fitting on screen.
    private var resultList: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                resultRows
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, index in
                guard model.results.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    reader.scrollTo(model.results[index].id, anchor: .center)
                }
            }
        }
    }

    private var resultRows: some View {
        VStack(spacing: 2) {
            if case .empty = model.state, !model.results.isEmpty {
                HStack {
                    Text(model.mode == .clipboard ? L("CLIPBOARD") : L("BEBRAIN / RECENT"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                ResultRow(result: result, selected: index == model.selection)
                    .id(result.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.select(index)
                        model.runSelected()
                    }
                    .onHover { inside in if inside, !model.isActionPanelOpen { model.select(index) } }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var emptyLaunchpad: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                sectionHeader(L("BEBRAIN QUICK ACTIONS"))
                VStack(spacing: 2) {
                    ForEach(brainEntries, id: \.result.id) { entry in
                        ResultRow(result: entry.result, selected: entry.index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(entry.index)
                                model.runSelected()
                            }
                            .onHover { inside in
                                if inside, !model.isActionPanelOpen { model.select(entry.index) }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

                Divider().overlay(.white.opacity(0.07))
                sectionHeader(L("CLIPBOARD HISTORY"))
                    .padding(.top, 2)
                ClipboardCarousel(model: model, entries: clipEntries)
            }
        }
        .scrollIndicators(.never)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: newNote) {
                Label(L("New note"), systemImage: "note.text.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(L("Write a quick note"))
            Button(action: recordVoice) {
                Label(L("Record"), systemImage: "waveform")
            }
            .buttonStyle(.borderless)
            .help(L("Record a voice note"))
            Button(action: dictate) {
                Label(L("Dictate"), systemImage: "text.cursor")
            }
            .buttonStyle(.borderless)
            .help(L("Dictate into the current app"))
            Text(countLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            if let primary = model.actions.first {
                KeyCap(symbol: "↩", label: primary.title)
            }
            if model.selected != nil {
                Divider().frame(height: 12).overlay(.white.opacity(0.12))
                Button { model.handle(.actionPanel) } label: {
                    KeyCap(symbol: "⌘K", label: L("Actions"))
                }
                .buttonStyle(.plain)
            }
            Button(action: openSettings) {
                KeyCap(symbol: "⌘,", label: L("Settings"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var countLabel: String {
        switch model.state {
        // Singular and plural are separate strings rather than one string plus an "s". English and
        // Spanish happen to agree on adding one letter; most languages this product might reach
        // later do not, and a counter is exactly where that shows.
        case .results:
            model.results.count == 1
                ? L("%@ result", "1")
                : L("%@ results", String(model.results.count))
        case .empty:
            model.results.isEmpty
                ? L("Try 2+2 · 10 km to mi · f report")
                : (model.mode == .clipboard ? L("Clipboard history") : L("Recent"))
        case .loading: L("Loading")
        case .noMatch: L("No results")
        case .failed: L("Error")
        }
    }
}

// MARK: - Search field bridge

private struct CommandSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusSeed: Int
    let wantsFocus: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.focus(field, seed: focusSeed, enabled: wantsFocus)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        private var lastFocusSeed: Int?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        func focus(_ field: NSTextField, seed: Int, enabled: Bool) {
            guard enabled else { return }
            let firstResponder = field.window?.firstResponder
            let alreadyFocused = firstResponder === field.currentEditor()
            guard lastFocusSeed != seed || !alreadyFocused else { return }
            lastFocusSeed = seed
            requestFocus(field)
            DispatchQueue.main.async { self.requestFocus(field) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.requestFocus(field) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.requestFocus(field) }
        }

        private func requestFocus(_ field: NSTextField) {
            guard let window = field.window, window.isVisible else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                (editor as? NSTextView)?.insertionPointColor = NSColor.white
                editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }
}

// MARK: - Detail pane

@MainActor
private struct DetailPane: View {
    let detail: ResultDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !detail.previewPath.isEmpty {
                    FilePreview(path: detail.previewPath)
                }

                Text(detail.body)
                    .font(detail.isMonospaced
                          ? .system(size: 12, design: .monospaced)
                          : .system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !detail.metadata.isEmpty {
                    Divider().overlay(.white.opacity(0.07))
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(detail.metadata) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.label)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 78, alignment: .leading)
                                Text(item.value)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Mission approval

@MainActor
private struct MissionPane: View {
    let mission: Mission
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Here is what it would do"), systemImage: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(mission.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(step.title)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if step.action.changesSomething {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .help(L("It changes something outside BeLauncher"))
                        }
                    }
                }
            }

            Text(L("Nothing runs until you approve it, and afterwards you get a receipt of what changed."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Ejecutar") { approve() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L("Cancel")) { cancel() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - AI answer

@MainActor
private struct AIPane: View {
    let state: LauncherModel.AIState
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .idle:
                EmptyView()

            case .working(let title):
                // A local model on a cold start can take half a minute, which without a way out
                // and without saying why reads as the whole machine having locked up.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        // Waiting is the other moment the mascot earns its place: something has
                        // to fill the seconds before the first word arrives.
                        Mascot(height: 34, isWorking: true)
                        Text(title).font(.system(size: 12))
                        Spacer()
                        Button(L("Cancel")) { dismiss() }
                            .controlSize(.small)
                    }
                    Text(L("The first time each day takes a few seconds while the model loads into memory. After that it starts writing almost instantly."))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .answer(let verb, let text):
                HStack {
                    Label(verb, systemImage: "sparkles")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text(L("↩ copy")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Volver") { dismiss() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Action panel

@MainActor
private struct ActionPanelView: View {
    @Bindable var model: LauncherModel
    @FocusState.Binding var focus: CommandView.Field?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(ResultAction.Section.allCases, id: \.self) { section in
                        let items = model.visibleActions.filter { $0.section == section }
                        if !items.isEmpty {
                            if !section.label.isEmpty {
                                Text(section.label.uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(0.7)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(items) { action in
                                row(action)
                            }
                        }
                    }
                    if model.visibleActions.isEmpty {
                        Text(L("No action matches"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 260)

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(L("Search actions…"), text: $model.actionQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: .actions)
                    .onSubmit {
                        if let action = model.selectedAction { model.run(action) }
                    }
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
        }
        .frame(width: 300)
        .background(GlassSurface())
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    @ViewBuilder
    private func row(_ action: ResultAction) -> some View {
        let index = model.visibleActions.firstIndex(of: action) ?? 0
        let selected = index == model.actionSelection

        HStack(spacing: 9) {
            Image(systemName: action.symbol)
                .font(.system(size: 11))
                .frame(width: 15)
                .foregroundStyle(action.isDestructive ? Theme.destructive : Theme.accent)
            Text(action.title)
                .font(.system(size: 12, weight: action.isDestructive ? .medium : .regular))
                .foregroundStyle(action.isDestructive ? Theme.destructive : .primary)
            Spacer(minLength: 8)
            if let shortcut = action.shortcut {
                Text(shortcut.display)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.25) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.run(action) }
        .onHover { inside in if inside { model.selectAction(index) } }
    }
}

// MARK: - Result row

@MainActor
private struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title.highlighting(result.matched))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(result.kind.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.white.opacity(0.08), in: Capsule())
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.22)) : AnyShapeStyle(Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.12 : 0), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var icon: some View {
        if result.kind == .application || result.kind == .file {
            Image(nsImage: IconCache.applicationIcon(path: result.payload))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: result.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - Seeing the thing instead of reading about it

/// Shows a copied image or a found file, and lets you do the obvious things with it.
///
/// The clipboard could already hold images and files, and the preview described them in words:
/// a screenshot you copied thirty seconds ago appeared as its dimensions. You cannot pick the right
/// one out of a list of "PNG · 1284×2778". So: the actual image, a thumbnail for anything else, and
/// the three things people reach for — drag it into another app, reveal it, open it.
@MainActor
private struct FilePreview: View {
    let path: String

    @State private var thumbnail: NSImage?

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
            // Dragging out is the whole point of a visual preview: grab the screenshot you copied
            // and drop it into the message you are writing.
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help(L("Drag it into any app"))

            HStack(spacing: 6) {
                QuickAction(symbol: "hand.draw", title: L("Drag from the image"))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("Finder", systemImage: "folder") }
                Button {
                    NSWorkspace.shared.open(url)
                } label: { Label(L("Open"), systemImage: "arrow.up.forward.app") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
        }
        .task(id: path) { await load() }
    }

    /// Quick Look renders anything macOS can preview, so a PDF or a video gets a real frame rather
    /// than a generic document icon. Images are read directly: asking Quick Look for a thumbnail of
    /// a PNG throws away the resolution we already have.
    private func load() async {
        thumbnail = nil
        if let image = NSImage(contentsOf: url), image.isValid {
            thumbnail = image
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 640, height: 380),
            scale: 2, representationTypes: .all
        )
        let generated = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        thumbnail = generated.map { NSImage(cgImage: $0.cgImage, size: .zero) }
            ?? NSWorkspace.shared.icon(forFile: path)
    }
}

private struct QuickAction: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - The clipboard, as things you can see

/// Clipboard history as a row of cards instead of a list of lines.
///
/// This is the one place in the app where a card beats a row, and the reason is specific: clipboard
/// items are the only results you recognise by *looking* — a screenshot, a logo, a block of JSON, a
/// paragraph. A vertical list of truncated text throws that away and makes you read to identify
/// something you would have known at a glance.
///
/// Everything else stays a list on purpose. Commands and recents are recognised by *reading*, and
/// scanning text horizontally is slower than scanning it down a column. A carousel there would look
/// better and work worse.
@MainActor
struct ClipboardCarousel: View {
    @Bindable var model: LauncherModel
    let entries: [(index: Int, result: SearchResult)]?

    init(model: LauncherModel, entries: [(index: Int, result: SearchResult)]? = nil) {
        self.model = model
        self.entries = entries
    }

    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 152

    private var visibleEntries: [(index: Int, result: SearchResult)] {
        entries ?? Array(model.results.enumerated()).map { ($0.offset, $0.element) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.result.id) { position, entry in
                        let index = entry.index
                        let result = entry.result
                        ClipCard(result: result,
                                 index: position,
                                 selected: index == model.selection)
                            .id(index)
                            .onTapGesture {
                                model.select(index)
                                model.runSelected()
                            }
                            .onHover { inside in
                                if inside, !model.isActionPanelOpen { model.select(index) }
                            }
                            // Right-click is where people already look for "what can I do with
                            // this", so the same verbs as ⌘K live here too.
                            .contextMenu {
                                ForEach(model.actions) { action in
                                    Button(action.title) { model.select(index); model.run(action) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: model.selection) { _, new in
                guard visibleEntries.contains(where: { $0.index == new }) else { return }
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: Self.cardHeight + 24)
    }
}

/// One clipboard item, big enough to recognise without reading.
@MainActor
private struct ClipCard: View {
    let result: SearchResult
    let index: Int
    let selected: Bool

    @State private var image: NSImage?

    private var previewPath: String { result.previewPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            HStack(spacing: 5) {
                // The icon of the app you copied from does the recognising faster than its name
                // ever could, and it fits where "Copiado de Google C…" did not.
                if let icon = sourceIcon {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                if result.subtitle.contains("Fijado") {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8)).foregroundStyle(Theme.cyan)
                }
                Text(sourceName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if index < 10 {
                    Text("⌃⌘\(index)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .frame(width: ClipboardCarousel.cardWidth, height: ClipboardCarousel.cardHeight)
        .background(.white.opacity(selected ? 0.09 : 0.04),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Theme.cyan : .white.opacity(0.07),
                              lineWidth: selected ? 1.6 : 1)
        )
        .task(id: previewPath) { await loadImage() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: ClipboardCarousel.cardWidth,
                       height: ClipboardCarousel.cardHeight - 30)
                .clipped()
        } else {
            Text(result.title)
                .font(.system(size: 11.5,
                              design: looksLikeCode ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .padding(.top, 9)
        }
    }

    /// "📌 Fijado · Imagen · Copiado de Google Chrome" → "Google Chrome".
    private var sourceName: String {
        guard let last = result.subtitle.split(separator: "·").last else { return "" }
        return last.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: L("Copied from "), with: "")
    }

    /// Resolved by name because that is all a clip records. A miss simply shows no icon rather
    /// than a generic placeholder, which would be noise repeated on every card.
    private var sourceIcon: NSImage? {
        let name = sourceName
        guard !name.isEmpty, name != L("Clipboard") else { return nil }
        for base in ["/Applications", "/System/Applications",
                     NSHomeDirectory() + "/Applications"] {
            let path = "\(base)/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return IconCache.applicationIcon(path: path)
            }
        }
        return nil
    }

    /// Code reads as code. A JSON blob in a proportional font is another wall of grey.
    private var looksLikeCode: Bool {
        let text = result.title
        return text.contains("{") || text.contains("</") || text.contains("=>")
            || text.hasPrefix("$ ") || text.contains(";\n")
    }

    private func loadImage() async {
        image = nil
        guard !previewPath.isEmpty else { return }
        let url = URL(fileURLWithPath: previewPath)
        guard let loaded = NSImage(contentsOf: url), loaded.isValid else { return }
        image = loaded
    }
}
