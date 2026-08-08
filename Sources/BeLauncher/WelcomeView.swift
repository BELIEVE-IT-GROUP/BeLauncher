import SwiftUI
import AppKit
import BeLauncherCore

/// The first five minutes, which until now did not exist.
///
/// The app opened to an empty search box and expected the person to already know what could be
/// typed into it. Everything it could do was reachable and nothing was findable. Three steps, once:
/// what you get, what it needs and why, and five things to try.
@MainActor
struct WelcomeView: View {
    let model: SettingsModel
    let onFinish: () -> Void

    @State private var step = 0
    @State private var health = CapabilityHealth()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(index == step ? Theme.accent : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                if step > 0 {
                    Button(L("Back")) { step -= 1 }
                }
                Button(step == 2 ? L("Get started") : L("Next")) {
                    if step == 2 { onFinish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 620)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: intro
        case 1: permissions
        default: firstSteps
        }
    }

    // MARK: - What this is

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Mascot(height: 104)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BeLauncher").font(.system(size: 26, weight: .semibold))
                            .tracking(-0.4)
                        Text(L("One key for everything you do on your Mac."))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }

                Text(L("Press **⇧⌘Space** whenever you like and start typing. It opens apps and files, works out sums, converts things, keeps what you copy, fires off multi-step flows and answers questions about what your company already decided."))

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("Your data stays here"), systemImage: "lock.shield")
                            .font(.system(size: 13, weight: .semibold))
                        Text(Onboarding.privacy)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Permissions, all of them, up front

    private var permissions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("What do you want it to be able to do"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L("Switch on whatever is useful to you. You can change it any time in Settings, and under each one it says exactly what it reaches and what happens if you leave it off."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                ForEach(Onboarding.capabilities) { capability in
                    CapabilityCard(capability: capability, model: model, health: health)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Five things to try

    private var firstSteps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Five things and you know how to use it"))
                    .font(.system(size: 18, weight: .semibold))

                GroupBox(L("The keys")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Onboarding.firstThings, id: \.keys) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.keys)
                                    .font(.system(size: 11, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    .frame(width: 96, alignment: .leading)
                                Text(item.does).font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox(L("Type this and see what happens")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Onboarding.tryThis, id: \.type) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.type)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.cyan)
                                    .frame(width: 150, alignment: .leading)
                                Text(item.andSee).font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(6)
                }

                Text(L("And when you cannot remember what you can type, open Settings → **What I can type**: it is all listed there."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

/// One capability: what it gives you, what it touches, and what you lose by saying no.
@MainActor
private struct CapabilityCard: View {
    let capability: Onboarding.Capability
    let model: SettingsModel
    let health: CapabilityHealth
    @State private var permissionRevision = 0
    @State private var isRequesting = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: capability.symbol)
                        .foregroundStyle(Theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(capability.title).font(.system(size: 13, weight: .semibold))
                            if capability.recommended {
                                Text(L("recommended"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.accent.opacity(0.18),
                                                in: Capsule())
                            }
                        }
                        Text(capability.unlocks).font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    capabilityControl
                }

                VStack(alignment: .leading, spacing: 3) {
                    Label(capability.accesses, systemImage: "eye")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Label(L("If you leave it off: %@", capability.ifYouSayNo), systemImage: "minus.circle")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRevision += 1
            health.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification)) { _ in
                // Returning from Privacy & Security does not always make a menu-bar app active.
                // Refresh on workspace activation as well so the check reflects TCC immediately.
                permissionRevision += 1
                health.refresh()
            }
    }

    @ViewBuilder
    private var capabilityControl: some View {
        if capability.isSystemPermission {
            if permissionIsReady {
                Label(L("Granted"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button {
                    requestSystemPermission()
                } label: {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(permissionButtonTitle,
                              systemImage: permissionNeedsSettings ? "gearshape" : "plus.circle")
                    }
                }
                .controlSize(.small)
                .disabled(isRequesting)
            }
        } else {
            Toggle("", isOn: preferenceBinding).labelsHidden()
        }
    }

    private var permissionIsReady: Bool {
        _ = permissionRevision
        return switch capability.kind {
        case .accessibility: health.accessibility.isReady
        case .automation: health.automation.isReady
        case .screen: health.screenRecording.isReady
        case .calendar: model.calendarGranted
        case .notifications: model.notificationsGranted
        case .microphone: health.microphone.isReady
        case .fullDiskAccess: health.fullDiskAccess.isReady
        default: false
        }
    }

    private var permissionNeedsSettings: Bool {
        switch capability.kind {
        case .microphone: Permissions.microphoneStatus == .denied
        case .accessibility, .automation, .screen, .fullDiskAccess: true
        default: false
        }
    }

    private var permissionButtonTitle: String {
        permissionNeedsSettings ? L("Open settings") : L("Allow")
    }

    private func requestSystemPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        switch capability.kind {
        case .accessibility:
            _ = health.requestAccessibility(reason: capability.unlocks)
            finishPermissionRequest()
        case .automation:
            health.requestAutomation()
            finishPermissionRequest()
        case .screen:
            health.requestScreenRecording()
            finishPermissionRequest()
        case .calendar:
            Task { @MainActor in
                await model.requestCalendarAndRefresh()
                finishPermissionRequest()
            }
        case .notifications:
            model.requestNotifications()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                model.refreshNotificationPermission()
                finishPermissionRequest()
            }
        case .microphone:
            Task { @MainActor in
                _ = await health.requestMicrophone()
                finishPermissionRequest()
            }
        case .fullDiskAccess:
            health.openFullDiskAccessSettings()
            finishPermissionRequest()
        default:
            finishPermissionRequest()
        }
    }

    private func finishPermissionRequest() {
        health.refresh()
        permissionRevision &+= 1
        isRequesting = false
    }

    /// System permissions cannot be switched on from here — macOS has to ask. Flipping the toggle
    /// triggers that request, and it stays off until macOS actually grants it, so the switch never
    /// claims something that is not true.
    private var preferenceBinding: Binding<Bool> {
        switch capability.kind {
        case .clipboard:
            Binding(get: { model.clipboardEnabled }, set: { model.clipboardEnabled = $0 })
        case .updates:
            Binding(get: { model.updateCheckEnabled }, set: { model.updateCheckEnabled = $0 })
        case .launchAtLogin:
            Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
        case .accessibility, .automation, .screen, .calendar, .notifications,
             .microphone, .fullDiskAccess:
            .constant(false)
        }
    }
}
