import SwiftUI
import AppKit
import BeLauncherCore

@MainActor
struct SourcesTab: View {
    @Bindable var model: SettingsModel
    @State private var health = CapabilityHealth()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: health.fullDiskAccess.isReady ? "lock.open" : "lock")
                        .foregroundStyle(health.fullDiskAccess.isReady ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(health.fullDiskAccess.isReady
                             ? L("Full Disk Access granted")
                             : L("Full Disk Access unlocks local Mail, Messages and Notes"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("Nothing leaves this Mac. Each connector keeps only relevant evidence and a reference to its original source."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !health.fullDiskAccess.isReady {
                        Button(L("Open settings")) { health.openFullDiskAccessSettings() }
                    }
                }
            }

            Section {
                Toggle(isOn: $model.graphEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Keep my Brain up to date"))
                        Text(L("Read only the enabled local sources and keep links to their originals."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.corpusStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let problem = model.corpusLastProblem, !problem.isEmpty {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                        }
                        if let feedback = model.sourceFeedback["all"] {
                            Text(feedback).font(.caption)
                                .foregroundStyle(model.sourceFeedbackErrors["all"] == true
                                                 ? Color.orange : Color.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.syncAllSources()
                    } label: {
                        if model.sourceIsSyncing("all") {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L("Sync all"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(!model.graphEnabled || !model.sourceSyncing.isEmpty)
                }
            }

            Section(L("Connected and available")) {
                ForEach(KnowledgeSourceCatalog.current) { source in
                    SourceRow(source: source, model: model)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            health.refresh()
            model.refreshBrainState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            health.refresh()
            model.refreshBrainState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification)) { _ in
                health.refresh()
                model.refreshBrainState()
        }
    }
}

@MainActor
private struct SourceRow: View {
    let source: KnowledgeSource
    @Bindable var model: SettingsModel

    var body: some View {
        let _ = model.sourceRefreshRevision
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.symbol).foregroundStyle(source.state == .planned ? .secondary : Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(source.title).font(.system(size: 12, weight: .medium))
                    Text(stateLabel).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stateColor)
                }
                Text(source.scope).font(.caption).foregroundStyle(.secondary)
                if let status = model.sourceStatusLine(source.id) {
                    Text(status).font(.system(size: 10))
                        .foregroundStyle(model.sourceFeedbackErrors[source.id] == true
                                         ? Color.orange : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 3)
        .id(model.sourceRefreshRevision)
    }

    @ViewBuilder
    private var action: some View {
        switch source.id {
        case "calendar" where !model.calendarGranted:
            Button(L("Allow")) { model.requestCalendar() }
                .controlSize(.small)
        case "reminders" where !model.remindersGranted:
            Button(L("Allow")) { model.requestReminders() }
                .controlSize(.small)
        case "audio":
            Text(L("Manual")).font(.caption).foregroundStyle(.secondary)
        case "notes", "messages", "apple-mail", "browsers", "conversations":
            HStack(spacing: 8) {
                Button { model.syncSource(source.id) } label: {
                    if model.sourceIsSyncing(source.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help(L("Sync now"))
                .disabled(!model.graphEnabled || !model.sourceEnabled(source.id)
                          || model.sourceIsSyncing(source.id))
                Toggle("", isOn: Binding(get: {
                    model.sourceEnabled(source.id)
                }, set: { value in
                    model.setSourceEnabled(source.id, value)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.sourceEnabled(source.id) ? L("Disable source") : L("Enable source"))
            }
        case "clipboard":
            Toggle("", isOn: $model.clipboardEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case "planned", "whatsapp", "mail-and-chats":
            Text(L("Coming later")).font(.caption).foregroundStyle(.secondary)
        default:
            Image(systemName: effectiveState == .connected ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(stateColor)
                .help(source.scope)
        }
    }

    private var effectiveState: KnowledgeSource.State {
        switch source.id {
        case "calendar":
            return model.calendarGranted ? .connected : .available
        case "reminders":
            return model.remindersGranted ? .connected : .available
        default:
            return LocalSourceHealth.state(for: source, store: model.store)
        }
    }

    private var stateLabel: String {
        switch effectiveState {
        case .connected: L("Connected")
        case .available: L("Available")
        case .manual: L("Manual")
        case .planned: L("Planned")
        }
    }

    private var stateColor: Color {
        switch effectiveState {
        case .connected: .green
        case .available: .orange
        case .manual: .secondary
        case .planned: .secondary
        }
    }
}
