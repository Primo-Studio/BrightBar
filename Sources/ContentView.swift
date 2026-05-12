import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: BrightnessManager

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
                        DisplaySliderView(display: display)
                    }
                }

                PresetRowView()
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
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

            Spacer()

            if let message = manager.lastErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            }

            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var keyboardStatusText: String {
        switch (manager.brightnessKeyMode, manager.optionHotkeysEnabled) {
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
        manager.brightnessKeyMode != .disabled || manager.optionHotkeysEnabled ? "keyboard" : "keyboard.badge.ellipsis"
    }

    private var keyboardStatusColor: Color {
        switch manager.brightnessKeyMode {
        case .intercepting:
            .secondary
        case .observing:
            .orange
        case .disabled:
            manager.optionHotkeysEnabled ? .secondary : .orange
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
        }
    }
}

private struct DisplaySliderView: View {
    let display: DisplayInfo
    @EnvironmentObject private var manager: BrightnessManager

    @State private var sliderValue: Double

    init(display: DisplayInfo) {
        self.display = display
        _sliderValue = State(initialValue: display.brightness)
    }

    var body: some View {
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
                        .foregroundStyle(statusColor)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int((sliderValue * 100).rounded()))%")
                    Text("~\(display.estimatedNits) nits")
                }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
            }

            Slider(
                value: $sliderValue,
                in: display.minBrightness...display.maxBrightness,
                step: 0.01
            )
            .disabled(!display.isControllable)
            .onChange(of: sliderValue) { _, newValue in
                manager.setBrightness(for: display.id, to: newValue)
            }

            if display.lastWriteFailed {
                Label("Echec DDC: active DDC/CI dans le menu de l'ecran.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if display.isSoftwareDimmed {
                Label("Sub-zero actif", systemImage: "moon.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            Stepper(
                value: Binding(
                    get: { display.maxNits },
                    set: { manager.setMaxNits(for: display.id, to: $0) }
                ),
                in: 80...2_000,
                step: 50
            ) {
                Text("Max \(Int(display.maxNits)) nits")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("Pic lumineux theorique de cet ecran, utilise pour estimer les nits.")
        }
        .onChange(of: display.brightness) { _, newValue in
            if abs(sliderValue - newValue) > 0.001 {
                sliderValue = newValue
            }
        }
    }

    private var statusColor: Color {
        switch display.controlKind {
        case .native, .ddc:
            display.lastWriteFailed ? .orange : .secondary
        case .unsupported:
            .orange
        }
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
