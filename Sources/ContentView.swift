import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: BrightnessManager

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.yellow)
                Text("BrightBar")
                    .font(.headline)
                Spacer()
                Button {
                    manager.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh displays")
            }

            Divider()

            if manager.displays.isEmpty {
                Text("No displays found")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(manager.displays) { display in
                    DisplaySliderView(display: display)
                }
            }

            Divider()

            // Bottom controls
            HStack {
                // Night mode toggle
                Button {
                    manager.toggleNightMode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: manager.nightModeActive ? "moon.fill" : "moon")
                            .foregroundStyle(manager.nightModeActive ? .indigo : .secondary)
                        Text("Night")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Toggle night mode (10% brightness)")

                Spacer()

                Text("⌥↑↓ adjust")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

struct DisplaySliderView: View {
    let display: DisplayInfo
    @EnvironmentObject var manager: BrightnessManager

    @State private var sliderValue: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((sliderValue * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(
                    value: $sliderValue,
                    in: display.minBrightness...display.maxBrightness,
                    step: 0.01
                )
                .onChange(of: sliderValue) { _, newValue in
                    manager.setBrightness(for: display.id, to: newValue)
                }

                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if display.isBuiltIn && sliderValue > 1.0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Boosted — may cause color shift")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            }

            if display.isOverlayActive {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                    Text("Overlay active (below minimum)")
                        .font(.caption2)
                }
                .foregroundStyle(.blue)
            }
        }
        .onAppear {
            sliderValue = display.brightness
        }
        .onChange(of: display.brightness) { _, newValue in
            if abs(sliderValue - newValue) > 0.001 {
                sliderValue = newValue
            }
        }
    }
}
