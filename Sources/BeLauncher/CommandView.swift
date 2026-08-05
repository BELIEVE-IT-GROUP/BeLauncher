import SwiftUI
import BeLauncherCore

@MainActor
struct CommandView: View {
    @Bindable var model: LauncherModel
    let openSettings: () -> Void

    @FocusState private var focus: Field?

    enum Field: Hashable { case search, actions }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if showsBody {
                Divider().overlay(.white.opacity(0.08))
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
            Divider().overlay(.white.opacity(0.08))
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(GlassBackground())
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
        .onAppear { focus = .search }
        .onChange(of: model.focusToken) { focus = .search }
        .onChange(of: model.isActionPanelOpen) { focus = model.isActionPanelOpen ? .actions : .search }
        .animation(.easeOut(duration: 0.12), value: model.results)
        .animation(.easeOut(duration: 0.12), value: model.state)
        .animation(.easeOut(duration: 0.1), value: model.isActionPanelOpen)
    }

    private var showsBody: Bool {
        switch model.state {
        case .results, .noMatch, .loading, .failed: true
        case .empty: !model.results.isEmpty
        }
    }

    /// The list drives the height, so showing a detail never makes the window jump.
    private var bodyHeight: CGFloat? {
        switch model.state {
        case .results, .empty:
            let rows = min(model.results.count, SearchEngine.resultLimit)
            let header: CGFloat = (model.state == .empty && !model.results.isEmpty) ? 24 : 0
            return CGFloat(rows) * (Theme.rowHeight + 2) + 16 + header
        case .loading, .noMatch, .failed:
            return nil
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 13) {
            AppIconView(side: 26)

            TextField("Search apps, snippets and clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($focus, equals: .search)
                .onSubmit { model.handle(.enter) }

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
                .help("Clear")
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
                Text("Indexing your applications…")
            }

        case .empty, .results:
            resultList

        case .noMatch:
            message {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No results for “\(model.query)”").fontWeight(.medium)
                    Text("Try an app name, a snippet keyword, or a workflow like “gh swift”.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let reason):
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BeLauncher could not read its database").fontWeight(.medium)
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Retry") { model.retry() }.controlSize(.small)
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

    private var resultList: some View {
        VStack(spacing: 2) {
            if case .empty = model.state, !model.results.isEmpty {
                HStack {
                    Text(model.mode == .clipboard ? "PORTAPAPELES" : "RECIENTES")
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.select(index)
                        model.runSelected()
                    }
                    .onHover { inside in if inside, !model.isActionPanelOpen { model.select(index) } }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
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
                    KeyCap(symbol: "⌘K", label: "Acciones")
                }
                .buttonStyle(.plain)
            }
            Button(action: openSettings) {
                KeyCap(symbol: "⌘,", label: "Ajustes")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var countLabel: String {
        switch model.state {
        case .results: "\(model.results.count) resultado\(model.results.count == 1 ? "" : "s")"
        case .empty:
            model.results.isEmpty
                ? "Prueba 2+2 · 10 km to mi · f informe"
                : (model.mode == .clipboard ? "Historial del portapapeles" : "Recientes")
        case .loading: "Cargando"
        case .noMatch: "Sin resultados"
        case .failed: "Error"
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
            Label("Esto es lo que haría", systemImage: "wand.and.stars")
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
                                .help("Cambia algo fuera de BeLauncher")
                        }
                    }
                }
            }

            Text("Nada se ejecuta hasta que lo apruebes, y después verás un recibo de lo que cambió.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Ejecutar") { approve() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancelar") { cancel() }
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                }

            case .answer(let verb, let text):
                HStack {
                    Label(verb, systemImage: "sparkles")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text("↩ copiar").font(.system(size: 10)).foregroundStyle(.tertiary)
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
                            if !section.rawValue.isEmpty {
                                Text(section.rawValue.uppercased())
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
                        Text("Ninguna acción coincide")
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
                TextField("Buscar acciones…", text: $model.actionQuery)
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
        .background(GlassBackground())
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
