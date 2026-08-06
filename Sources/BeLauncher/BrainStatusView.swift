import SwiftUI
import AppKit
import BeLauncherCore

/// What the brain holds, in numbers a person can check against what they know they wrote.
///
/// This replaces the block that lived inside `SettingsView`, and it exists for one reason: nobody
/// hands their working memory to something they have to take at its word. "Tu cerebro está listo"
/// is a claim. "1.240 fragmentos, 900 entienden lo que quieres decir, 12 ratos de trabajo, 41
/// nombres conocidos" is a set of numbers that can be wrong, and being able to catch it being
/// wrong is exactly what makes it usable.
///
/// Three states, all real: counting while the numbers are being read, the empty one saying so
/// instead of showing five zeros with no explanation, and a failure that names what happened.
@MainActor
struct BrainStatusView: View {
    @Bindable var model: SettingsModel
    let installer: ModelInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.brainError {
                Failure(text: error) { model.refreshBrainState() }
            } else if let readout = model.brainReadout {
                Headline(readout: readout)

                if readout.passages > 0 {
                    Counts(model: model)
                    if !readout.needsModel {
                        ProgressView(value: readout.percent)
                            .progressViewStyle(.linear)
                            .opacity(readout.isComplete ? 0.35 : 1)
                    }
                }

                Label(readout.engineLine,
                      systemImage: readout.needsModel ? "questionmark.circle" : "cpu")
                    .font(.system(size: 11.5))
                    .foregroundStyle(readout.needsModel ? Color.primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.brainIsLocal ? PrivacyCopy.Brain.localLine : PrivacyCopy.Brain.remoteLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only when there is something to solve. Showing an installer to somebody who
                // already installed it is noise.
                if readout.needsModel {
                    ModelInstallControls(installer: installer)
                        .padding(.top, 2)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(PrivacyCopy.Brain.counting)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(model.brainRebuilding
                       ? BrainSetupCopy.rebuildRunning : BrainSetupCopy.rebuildTitle) {
                    model.rebuildIndex()
                }
                .disabled(model.brainRebuilding)
                if model.brainRebuilding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Actualizar") { model.refreshBrainState() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            Text(BrainSetupCopy.rebuildExplanation)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.brainStatus {
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.brainRebuilding)
    }
}

// MARK: - Pieces

@MainActor
private struct Headline: View {
    let readout: BrainSetupCopy.IndexReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(readout.passages == 0 ? PrivacyCopy.Brain.emptyHeadline : readout.headline)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(readout.passages == 0 ? PrivacyCopy.Brain.emptyDetail : readout.detail)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The five numbers, in a grid that reflows rather than clipping when the window narrows.
@MainActor
private struct Counts: View {
    @Bindable var model: SettingsModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(model.brainCards) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.cyan)
                    Text(card.label)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.hint)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.07)))
            }
        }
    }
}

@MainActor
private struct Failure: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Actualizar", action: retry).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.destructive).frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }
}
