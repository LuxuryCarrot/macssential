import SwiftUI

struct FinderSortSettingsView: View {
    @Bindable var module: FinderSortModule

    // Transient by design: AppDelegate rebuilds the NSHostingView on every
    // panel open, so the control always reopens collapsed.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Inline fake dropdown. A real popup control (.menu Picker,
            // SwiftUI Menu, NSPopUpButton, popover) cannot present inside an
            // NSMenu-hosted NSHostingView — the parent menu's tracking loop
            // owns all events (see d70466d). So the "dropdown" is an inline
            // expand/collapse within the same view hierarchy.
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "module.finder_sort.sort_by"))
                        .font(.caption)
                    Spacer()
                    Text(module.arrangeBy.localizedTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(FinderArrangeBy.allCases, id: \.self) { option in
                        let isSelected = module.arrangeBy == option
                        Button {
                            // Guard: arrangeBy's didSet applies + restarts
                            // Finder on every assignment, including same-value
                            // assignments. Same-value taps must only collapse.
                            if module.arrangeBy != option {
                                module.arrangeBy = option
                            }
                            isExpanded = false
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                    .opacity(isSelected ? 1 : 0)
                                    .frame(width: 12)
                                Text(option.localizedTitle)
                                    .font(.caption)
                                    .foregroundColor(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }

            // DEBUG-only: enforce is experimental, hidden in Release (see
            // FinderSortModule.startEnforceTimer).
            #if DEBUG
            // Enforce toggle: periodically re-applies the sort to ALL open
            // Finder windows via Apple Events, including folders with saved
            // view settings. Toggles work inside the NSMenu-hosted
            // NSHostingView — only popup-presenting controls are broken
            // (d70466d); Toggle precedent throughout the panel.
            Toggle(isOn: $module.enforceSort) {
                Text(String(localized: "module.finder_sort.enforce"))
                    .font(.caption)
            }
            .toggleStyle(PanelSwitchToggleStyle(size: .mini))

            Text(String(localized: "module.finder_sort.enforce_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif

            // Effect note: applying restarts Finder; folders with their own
            // saved view settings keep their existing sort.
            Text(String(localized: "module.finder_sort.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
