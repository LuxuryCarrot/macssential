import SwiftUI

struct KeyRepeatSettingsView: View {
    @Bindable var module: KeyRepeatModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Slider 1 — Delay Until Repeat (InitialKeyRepeat, 1/60 s ticks)
            HStack {
                Text(String(localized: "module.key_repeat.initial_delay"))
                    .font(.caption)
                Spacer()
                Text("\(KeyRepeatModule.milliseconds(forTicks: module.initialKeyRepeat)) ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(String(localized: "module.key_repeat.short"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(
                    value: intBinding($module.initialKeyRepeat),
                    in: Double(KeyRepeatModule.initialKeyRepeatRange.lowerBound)...Double(KeyRepeatModule.initialKeyRepeatRange.upperBound),
                    step: 1
                )
                Text(String(localized: "module.key_repeat.long"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Slider 2 — Repeat Rate (KeyRepeat, 1/60 s ticks per repeat)
            HStack {
                Text(String(localized: "module.key_repeat.repeat_rate"))
                    .font(.caption)
                Spacer()
                Text("\(KeyRepeatModule.milliseconds(forTicks: module.keyRepeat)) ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(String(localized: "module.key_repeat.fast"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(
                    value: intBinding($module.keyRepeat),
                    in: Double(KeyRepeatModule.keyRepeatRange.lowerBound)...Double(KeyRepeatModule.keyRepeatRange.upperBound),
                    step: 1
                )
                Text(String(localized: "module.key_repeat.slow"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Effect-timing note: live HID parameters make changes apply immediately in all apps.
            Text(String(localized: "module.key_repeat.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(String(localized: "module.key_repeat.restore_defaults")) {
                module.restoreMacOSDefaults()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Bridges an Int model property to the Double-based Slider API.
    private func intBinding(_ source: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(source.wrappedValue) },
            set: { source.wrappedValue = Int($0.rounded()) }
        )
    }
}
