import SwiftUI
import BeLauncherCore

@MainActor
struct CommandView: View {
    @Bindable var model: LauncherModel
    let openSettings: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if showsBody {
                Divider().overlay(.white.opacity(0.08))
                stateContent(model.state)
            }
            Divider().overlay(.white.opacity(0.08))
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(GlassBackground())
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(GlassEdge())
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .padding(Theme.shadowPadding)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
        .animation(.easeOut(duration: 0.12), value: model.results)
        .animation(.easeOut(duration: 0.12), value: model.state)
    }

    private var showsBody: Bool {
        switch model.state {
        case .results, .noMatch, .loading, .failed: true
        case .empty: !model.results.isEmpty
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 13) {
            BeLauncherMark(side: 22, color: .primary.opacity(0.85))

            TextField("Search apps, snippets and clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($searchFocused)
                .onSubmit { model.handle(.enter) }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BeLauncher could not read its database").fontWeight(.medium)
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") { model.retry() }
                    .controlSize(.small)
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
                    Text("RECENT CLIPBOARD")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }

            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                ResultRow(result: result, selected: index == model.selection)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.select(index)
                        model.runSelected()
                    }
                    .onHover { inside in if inside { model.select(index) } }
            }
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
            KeyCap(symbol: "↑↓", label: "navigate")
            if let kind = model.selected?.kind {
                switch kind {
                case .application, .file:
                    KeyCap(symbol: "⌘↩", label: "reveal")
                case .workflow:
                    KeyCap(symbol: "⇥", label: "complete")
                default:
                    EmptyView()
                }
            }
            KeyCap(symbol: "↩", label: runLabel)
            Button(action: openSettings) {
                KeyCap(symbol: "⌘,", label: "settings")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var runLabel: String {
        switch model.selected?.kind {
        case .calculation, .clipboard, .snippet: "copy"
        case .file: "open"
        default: "run"
        }
    }

    private var countLabel: String {
        switch model.state {
        case .results: "\(model.results.count) result\(model.results.count == 1 ? "" : "s")"
        case .empty:
            model.results.isEmpty
                ? "Try 2+2 · 10 km to mi · f report"
                : (model.mode == .clipboard ? "Clipboard history" : "Recent items")
        case .loading: "Loading"
        case .noMatch: "No results"
        case .failed: "Error"
        }
    }
}

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
        if result.kind == .application {
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
