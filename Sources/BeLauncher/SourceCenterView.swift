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
                             ? L("Deep local sources are ready")
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

            Section(L("Connected and available")) {
                ForEach(KnowledgeSourceCatalog.current) { source in
                    SourceRow(source: source, model: model, health: health)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            health.refresh()
        }
    }
}

@MainActor
private struct SourceRow: View {
    let source: KnowledgeSource
    @Bindable var model: SettingsModel
    let health: CapabilityHealth
    @State private var enabled = true

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
                    Text(status).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 3)
        .id(model.sourceRefreshRevision)
        .onAppear { enabled = model.sourceEnabled(source.id) }
    }

    @ViewBuilder
    private var action: some View {
        switch source.id {
        case "calendar" where !model.calendarGranted:
            Button(L("Allow")) { model.requestCalendar() }
                .controlSize(.small)
        case "audio":
            Text(L("Manual")).font(.caption).foregroundStyle(.secondary)
        case "notes", "messages", "apple-mail":
            HStack(spacing: 8) {
                Button { model.syncSource(source.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("Sync now"))
                Toggle("", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    model.setSourceEnabled(source.id, value)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(enabled ? L("Disable source") : L("Enable source"))
            }
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
        case "notes", "messages", "apple-mail":
            guard health.fullDiskAccess.isReady, model.sourceHasSuccessfulSync(source.id) else {
                return .available
            }
            return .connected
        case "browsers":
            return model.browserSourceAvailable() ? .connected : .available
        case "clipboard":
            return model.clipboardHasEvidence() ? .connected : .available
        default:
            return source.state
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
