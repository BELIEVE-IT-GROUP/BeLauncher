import SwiftUI
import AppKit
import BeLauncherCore

@MainActor
@Observable
final class ActivationModel {
    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
        case limit(devices: [LicenseDevice], maxDevices: Int)
    }

    var email = ""
    var key = ""
    var phase: Phase = .idle

    private let client: LicenseClient
    private let onActivated: (LicenseIdentity) -> Void

    init(client: LicenseClient, onActivated: @escaping (LicenseIdentity) -> Void) {
        self.client = client
        self.onActivated = onActivated
    }

    var canSubmit: Bool {
        LicenseEmail.isPlausible(email) && LicenseKey.isWellFormed(key) && phase != .working
    }

    func activate() {
        guard canSubmit else { return }
        phase = .working
        let email = self.email, key = self.key
        Task { @MainActor in
            let outcome = await client.activate(
                email: email, key: key,
                deviceID: DeviceIdentity.id, deviceName: DeviceIdentity.name
            )
            switch outcome {
            case .activated:
                let identity = LicenseIdentity(
                    email: LicenseEmail.normalise(email),
                    key: LicenseKey.normalise(key),
                    deviceID: DeviceIdentity.id,
                    lastCheck: .now
                )
                do {
                    try LicenseVault.save(identity)
                    onActivated(identity)
                } catch {
                    phase = .failed("No pudimos guardar la licencia en el Llavero: \(error)")
                }
            case .deviceLimit(let devices, let max):
                phase = .limit(devices: devices, maxDevices: max)
            case .invalid, .serverError, .unreachable, .rejected:
                phase = .failed(outcome.message)
            }
        }
    }

    /// Frees a seat from the limit screen, then retries the activation.
    func release(_ device: LicenseDevice) {
        guard let deviceID = device.deviceID else { return }
        phase = .working
        let email = self.email, key = self.key
        Task { @MainActor in
            let freed = await client.deactivate(email: email, key: key, deviceID: deviceID)
            if freed {
                activate()
            } else {
                phase = .failed(L("We could not release that Mac. Try again in a moment."))
            }
        }
    }
}

@MainActor
struct ActivationView: View {
    @Bindable var model: ActivationModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                AppIconView(side: 88)
                    .padding(.top, 30)
                VStack(spacing: 5) {
                    Text(L("Activate BeLauncher"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(L("Lifetime licence · up to 3 Macs"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Correo de compra", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                TextField("BELN-XXXX-XXXX-XXXX", text: $model.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { model.activate() }

                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .limit(let devices, let max) = model.phase {
                    limitSection(devices: devices, maxDevices: max)
                }

                Button {
                    model.activate()
                } label: {
                    HStack(spacing: 7) {
                        if model.phase == .working { ProgressView().controlSize(.small) }
                        Text(model.phase == .working ? "Activando…" : "Activar")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSubmit)
                .padding(.top, 2)

                Text(L("The key arrives by email when you buy. It is kept in your Keychain and BeLauncher works offline from here on."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func limitSection(devices: [LicenseDevice], maxDevices: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("This licence is already on %@ Macs. Release one to activate this.", String(maxDevices)))
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            if devices.contains(where: { !$0.canBeReleased }) {
                Text(L("To release one, open it on that Mac and use Settings › Deactivate this Mac."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.system(size: 12))
                        if !device.since.isEmpty {
                            Text("desde \(device.since)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if device.canBeReleased {
                        Button(L("Release this Mac")) { model.release(device) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
