import CoreGraphics
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: BrightnessManager
    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if manager.displays.isEmpty {
                EmptyStateView(refresh: manager.refreshDisplays)
            } else {
                GlobalBrightnessView()

                Divider()

                VStack(spacing: 12) {
                    ForEach(manager.displays) { display in
                        DisplaySliderView(displayID: display.id)
                    }
                }

                PresetRowView()
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            manager.refreshKeyboardHooks()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text("BrightBar")
                    .font(.headline)
                Text(manager.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                manager.setEnabled(!manager.isEnabled)
            } label: {
                Image(systemName: manager.isEnabled ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(manager.isEnabled ? .green : .orange)
            }
            .buttonStyle(.borderless)
            .help(manager.isEnabled ? "Desactiver BrightBar" : "Activer BrightBar")

            Button {
                manager.refreshDisplays()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Actualiser les ecrans")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(keyboardStatusText, systemImage: keyboardStatusIcon)
                .font(.caption)
                .foregroundStyle(keyboardStatusColor)
                .help(keyboardStatusHelp)

            Spacer()

            if let message = manager.lastErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            }

            Button {
                updateManager.checkForUpdates()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!updateManager.canCheckForUpdates)
            .help("Verifier les mises a jour")

            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var keyboardStatusText: String {
        guard manager.isEnabled else { return "BrightBar desactive" }

        return switch (manager.brightnessKeyMode, manager.optionHotkeysEnabled) {
        case (.intercepting, true):
            "Soleil / Opt+fleches"
        case (.intercepting, false):
            "Soleil actif"
        case (.observing, true):
            "Soleil observe / Opt"
        case (.observing, false):
            "Soleil observe"
        case (.disabled, true):
            "Opt+fleches actif"
        case (.disabled, false):
            "Clavier non actif"
        }
    }

    private var keyboardStatusIcon: String {
        guard manager.isEnabled else { return "power" }
        return manager.brightnessKeyMode != .disabled || manager.optionHotkeysEnabled ? "keyboard" : "keyboard.badge.ellipsis"
    }

    private var keyboardStatusColor: Color {
        guard manager.isEnabled else { return .orange }

        return switch manager.brightnessKeyMode {
        case .intercepting:
            .secondary
        case .observing:
            .orange
        case .disabled:
            manager.optionHotkeysEnabled ? .secondary : .orange
        }
    }

    private var keyboardStatusHelp: String {
        guard manager.isEnabled else {
            return "BrightBar ne capte plus F1/F2 et coupe le dimming logiciel."
        }

        return switch manager.brightnessKeyMode {
        case .intercepting:
            "BrightBar intercepte F1/F2 et controle les ecrans."
        case .observing:
            "BrightBar voit F1/F2 mais macOS garde aussi la touche. Autorise BrightBar dans Reglages Systeme > Confidentialite et securite > Accessibilite."
        case .disabled:
            manager.optionHotkeysEnabled
                ? "Utilise Option + fleche haut/bas. Autorise BrightBar dans Accessibilite pour F1/F2."
                : "Autorise BrightBar dans Reglages Systeme > Confidentialite et securite > Accessibilite."
        }
    }
}

private struct GlobalBrightnessView: View {
    @EnvironmentObject private var manager: BrightnessManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tous les ecrans", systemImage: "rectangle.3.group")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(manager.averageBrightnessPercent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { manager.averageBrightness },
                        set: { manager.setAllBrightness(to: $0) }
                    ),
                    in: 0...1,
                    step: 0.01
                )

                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if manager.hasSoftwareOnlyDisplays {
                Label("Les ecrans en Logiciel dimment seulement: pas de boost hardware.", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !manager.isEnabled {
                Label("BrightBar est desactive: dimming coupe, F1/F2 rendus a macOS.", systemImage: "power")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DisplaySliderView: View {
    let displayID: CGDirectDisplayID
    @EnvironmentObject private var manager: BrightnessManager

    var body: some View {
        if let display {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(display.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Text(display.controlKind.rawValue)
                            .font(.caption2)
                            .foregroundStyle(statusColor(for: display))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(display.brightnessPercent)%")
                        Text(nitsText(for: display))
                    }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { currentDisplay?.brightness ?? display.brightness },
                        set: { manager.setBrightness(for: displayID, to: $0) }
                    ),
                    in: display.minBrightness...display.maxBrightness,
                    step: 0.01
                )
                .disabled(!manager.isEnabled || !display.isControllable)

                if display.lastWriteFailed {
                    Label("Echec DDC: active DDC/CI dans le menu de l'ecran.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let dimmingStatus = dimmingStatus(for: display) {
                    Label(dimmingStatus, systemImage: "moon.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                if display.controlKind == .software {
                    Label("DDC indisponible: BrightBar peut dimmer, pas booster le hardware.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(
                    value: Binding(
                        get: { currentDisplay?.maxNits ?? display.maxNits },
                        set: { manager.setMaxNits(for: displayID, to: $0) }
                    ),
                    in: 80...2_000,
                    step: 50
                ) {
                    Text("Max \(Int(display.maxNits)) nits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .disabled(!manager.isEnabled)
                .help("Pic lumineux theorique de cet ecran, utilise pour estimer les nits.")
            }
        }
    }

    private var display: DisplayInfo? {
        currentDisplay
    }

    private var currentDisplay: DisplayInfo? {
        manager.displays.first { $0.id == displayID }
    }

    private func statusColor(for display: DisplayInfo) -> Color {
        switch display.controlKind {
        case .native, .ddc:
            display.lastWriteFailed ? .orange : .secondary
        case .software:
            .blue
        case .unsupported:
            .orange
        }
    }

    private func nitsText(for display: DisplayInfo) -> String {
        let estimate = BrightnessMath.estimatedNits(
            maxNits: display.maxNits,
            brightness: display.brightness,
            controlKind: display.controlKind
        )
        return display.controlKind == .software ? "<=\(estimate) nits" : "~\(estimate) nits"
    }

    private func dimmingStatus(for display: DisplayInfo) -> String? {
        guard display.isSoftwareDimmed else { return nil }
        return display.controlKind == .software ? "Dimming logiciel actif" : "Sub-zero actif"
    }
}

private struct PresetRowView: View {
    @EnvironmentObject private var manager: BrightnessManager
    private let presets = [0.05, 0.2, 0.5, 1.0]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { preset in
                Button("\(Int(preset * 100))%") {
                    manager.setAllBrightness(to: preset)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!manager.isEnabled)
            }
        }
    }
}

private struct EmptyStateView: View {
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Aucun ecran detecte")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Reessayer", action: refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
