import SwiftUI

struct ControlPanel: View {
    // Injected rather than defaulted: BrightnessEngine is MainActor-isolated and a
    // stored-property default would be evaluated outside that isolation.
    @ObservedObject var engine: BrightnessEngine
    @ObservedObject var settings = Settings.shared
    @State private var showingAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            slider
            readout
            if showingAdvanced { Divider(); advanced }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Brightness")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(settings.enabled ? "Turn off and return to macOS brightness" : "Turn on")
        }
    }

    // MARK: - Slider

    /// One continuous track. The left half goes below the darkest setting macOS will
    /// give you, the right half goes above the brightest. Zero in the middle is
    /// untouched — moving the hardware brightness keys still works everywhere on
    /// the track, because this scales whatever macOS is already doing rather than
    /// replacing it.
    private var slider: some View {
        VStack(spacing: 6) {
            Slider(value: $settings.position, in: -1...1) {
                Text("Brightness")
            } minimumValueLabel: {
                Image(systemName: "moon")
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.enabled)

            HStack {
                Text("Darker than macOS")
                Spacer()
                Text("macOS")
                Spacer()
                Text(engine.status.boostAvailable ? "XDR" : "Not available")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(gainLabel)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                Spacer()
                Button("Reset") { settings.resetToNative() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(abs(settings.position) < 0.001)
            }

            if let note = statusNote {
                Label(note, systemImage: noteIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var gainLabel: String {
        let g = engine.status.appliedGain
        if abs(g - 1.0) < 0.01 { return "macOS default" }
        if g > 1 { return String(format: "%.2f× brighter", g) }
        return String(format: "%.0f%% of minimum", g * 100)
    }

    private var statusNote: String? {
        switch engine.status.suspension {
        case .none:
            if settings.position > 0 && !engine.status.boostAvailable {
                return "\(engine.status.displayName) has no extended range to unlock. Dimming still works."
            }
            if settings.position > 0 {
                return String(format: "Headroom in use: %.2f× of %.2f× available",
                              engine.status.appliedGain, engine.status.usableCeiling)
            }
            return nil
        case .thermal:
            return "Paused while the Mac cools down. It will come back on its own."
        case .lowPower:
            return "Paused in Low Power Mode."
        case .disabled:
            return nil
        case .locked, .asleep:
            return "Paused while the display is off."
        case .noDisplays:
            return "No display detected."
        }
    }

    private var noteIcon: String {
        switch engine.status.suspension {
        case .thermal: return "thermometer.high"
        case .lowPower: return "battery.25"
        case .none: return "info.circle"
        default: return "pause.circle"
        }
    }

    // MARK: - Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Peak headroom limit: \(Int(settings.sustainedFraction * 100))%")
                    .font(.caption)
                Slider(value: $settings.sustainedFraction, in: 0.3...1.0)
                Text("Above about 62% the panel can no longer hold the brightness across the whole screen and will fade back down after a few seconds.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dimming range: \(String(format: "%.1f", settings.dimStops)) stops")
                    .font(.caption)
                Slider(value: $settings.dimStops, in: 1...5)
            }

            Toggle("Pause when the Mac gets hot", isOn: $settings.suspendWhenHot)
            Toggle("Pause in Low Power Mode", isOn: $settings.suspendOnLowPower)
            Toggle("Include external displays", isOn: $settings.boostExternalDisplays)
        }
        .font(.caption)
        .toggleStyle(.checkbox)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(showingAdvanced ? "Hide settings" : "Settings") {
                withAnimation(.easeInOut(duration: 0.15)) { showingAdvanced.toggle() }
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
