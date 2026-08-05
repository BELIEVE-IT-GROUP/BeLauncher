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
                    Button("Atrás") { step -= 1 }
                }
                Button(step == 2 ? "Empezar" : "Siguiente") {
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
                HStack(spacing: 12) {
                    BeLauncherMark(side: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BeLauncher").font(.system(size: 22, weight: .semibold))
                        Text("Una tecla para todo lo que haces en el Mac.")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Pulsa **⇧⌘Espacio** en cualquier momento y escribe. Abre apps y archivos, "
                     + "calcula, convierte, guarda lo que copias, dispara flujos de varios pasos y "
                     + "responde preguntas sobre lo que tu empresa ya decidió.")

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Tus datos se quedan aquí", systemImage: "lock.shield")
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
                Text("Qué quieres que pueda hacer")
                    .font(.system(size: 18, weight: .semibold))
                Text("Enciende lo que te sirva. Puedes cambiarlo cuando quieras en Ajustes, y "
                     + "debajo de cada uno pone exactamente a qué accede y qué pasa si lo dejas "
                     + "apagado.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                ForEach(Onboarding.capabilities) { capability in
                    CapabilityCard(capability: capability, model: model)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Five things to try

    private var firstSteps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Cinco cosas y ya sabes usarlo")
                    .font(.system(size: 18, weight: .semibold))

                GroupBox("Las teclas") {
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

                GroupBox("Escribe esto y mira qué pasa") {
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

                Text("Y cuando no sepas qué se puede escribir, abre Ajustes → **Qué puedo escribir**: "
                     + "está todo listado.")
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
                                Text("recomendado")
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
                    Toggle("", isOn: binding).labelsHidden()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Label(capability.accesses, systemImage: "eye")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Label("Si lo dejas apagado: " + capability.ifYouSayNo, systemImage: "minus.circle")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    /// System permissions cannot be switched on from here — macOS has to ask. Flipping the toggle
    /// triggers that request, and it stays off until macOS actually grants it, so the switch never
    /// claims something that is not true.
    private var binding: Binding<Bool> {
        switch capability.kind {
        case .clipboard:
            Binding(get: { model.clipboardEnabled }, set: { model.clipboardEnabled = $0 })
        case .updates:
            Binding(get: { model.updateCheckEnabled }, set: { model.updateCheckEnabled = $0 })
        case .launchAtLogin:
            Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
        case .accessibility:
            Binding(get: { Permissions.accessibilityGranted },
                    set: { if $0 { Permissions.requestAccessibility(
                        reason: capability.unlocks) } })
        case .automation:
            // Asking macOS with askUserIfNeeded triggers the real prompt. If the person already
            // said no once, macOS will not ask again, so the pane is opened for them.
            Binding(get: { Permissions.automationGranted() },
                    set: { wanted in
                        guard wanted else { return }
                        if !Permissions.automationGranted(askUserIfNeeded: true) {
                            Permissions.openAutomationSettings()
                        }
                    })
        case .calendar:
            Binding(get: { model.calendarGranted },
                    set: { if $0 { model.requestCalendar() } })
        case .notifications:
            Binding(get: { model.notificationsGranted },
                    set: { if $0 { model.requestNotifications() } })
        }
    }
}
