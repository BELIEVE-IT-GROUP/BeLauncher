import SwiftUI
import AppKit
import BeLauncherCore

/// Builds a flow without writing anything that looks like code: pick a step kind, fill one
/// field, press +. The catalogue is closed, so there is nothing here that can run a script.
@MainActor
struct FlowEditor: View {
    @Bindable var model: SettingsModel

    @State private var newKeyword = ""
    @State private var newTitle = ""
    @State private var draft = StepDraft()
    @State private var editing: Int64?

    var body: some View {
        if model.flows.isEmpty {
            Text("No flows yet. A flow chains steps under one keyword.")
                .font(.caption).foregroundStyle(.secondary)
        }

        ForEach(model.flows) { flow in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(flow.title)
                        Text("\(flow.keyword) · \(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(editing == flow.id ? "Done" : "Edit steps") {
                        editing = editing == flow.id ? nil : flow.id
                    }
                    .controlSize(.small)
                    Button {
                        model.store.deleteFlow(id: flow.id)
                        model.reload()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Image(systemName: step.symbol).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Text(step.summary).font(.caption)
                        Spacer()
                        if editing == flow.id {
                            Button {
                                var steps = flow.steps
                                steps.remove(at: index)
                                model.updateFlow(flow.id, steps: steps)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.leading, 4)
                }

                if editing == flow.id {
                    stepBuilder { step in
                        model.updateFlow(flow.id, steps: flow.steps + [step])
                    }
                }
            }
            .padding(.vertical, 2)
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            TextField("Keyword", text: $newKeyword)
            TextField("Name", text: $newTitle, prompt: Text("Modo enfoque"))
            stepBuilder(label: "Create with first step") { step in
                if model.addFlow(keyword: newKeyword, title: newTitle, steps: [step]) {
                    newKeyword = ""; newTitle = ""
                }
            }
            if let error = model.flowError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Steps run in order. “Run shortcut” calls a shortcut you already made in the "
                 + "Shortcuts app — that is how a flow silences notifications or sets a Focus. "
                 + "BeLauncher never runs scripts of its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step builder

    private struct StepDraft {
        var kind: Kind = .openApp
        var text: String = ""
        var minutes: Int = 50

        enum Kind: String, CaseIterable, Identifiable {
            case openApp, openURL, openFile, copyText, runSnippet, runShortcut, timer, wait
            var id: String { rawValue }

            var label: String {
                switch self {
                case .openApp: "Open app"
                case .openURL: "Open URL"
                case .openFile: "Open file"
                case .copyText: "Copy text"
                case .runSnippet: "Paste snippet"
                case .runShortcut: "Run shortcut"
                case .timer: "Start timer"
                case .wait: "Wait"
                }
            }

            var placeholder: String {
                switch self {
                case .openApp: "/Applications/Notion.app"
                case .openURL: "https://…"
                case .openFile: "/Users/…/notes.md"
                case .copyText: "text to copy"
                case .runSnippet: "snippet keyword"
                case .runShortcut: "Shortcut name"
                case .timer: "label"
                case .wait: "seconds"
                }
            }
        }

        func build() -> FlowStep? {
            let value = text.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .openApp: return value.isEmpty ? nil : .openApp(path: value)
            case .openURL: return value.isEmpty ? nil : .openURL(url: value)
            case .openFile: return value.isEmpty ? nil : .openFile(path: value)
            case .copyText: return value.isEmpty ? nil : .copyText(text: value)
            case .runSnippet: return value.isEmpty ? nil : .runSnippet(keyword: value.lowercased())
            case .runShortcut: return value.isEmpty ? nil : .runShortcut(name: value)
            case .timer: return .timer(minutes: minutes, label: value.isEmpty ? "Timer" : value)
            case .wait: return .wait(seconds: Double(value) ?? 1)
            }
        }
    }

    @ViewBuilder
    private func stepBuilder(label: String = "Add step", add: @escaping (FlowStep) -> Void) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: $draft.kind) {
                ForEach(StepDraft.Kind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)

            if draft.kind == .openApp {
                Button("Choose…") { chooseApplication() }
                    .controlSize(.small)
            }
            if draft.kind == .runShortcut, !model.shortcutNames.isEmpty {
                Picker("", selection: $draft.text) {
                    Text("Pick…").tag("")
                    ForEach(model.shortcutNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            TextField(draft.kind.placeholder, text: $draft.text)
            if draft.kind == .timer {
                Stepper("\(draft.minutes) min", value: $draft.minutes, in: 1...240, step: 5)
                    .fixedSize()
            }
            Button(label) {
                guard let step = draft.build() else { return }
                add(step)
                draft.text = ""
            }
            .controlSize(.small)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.message = "Pick the app this step should open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.text = url.path
    }
}
