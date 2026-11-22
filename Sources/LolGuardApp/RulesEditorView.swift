import Foundation
import GuardCore
import SwiftUI

struct RulesEditorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.hasUnsavedChanges {
                    Text("Unsaved Changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                }

                Button("Reload") {
                    state.loadConfig()
                }
                .help("Discard unsaved edits and reload from config.json")

                Button("Save") {
                    state.saveConfig()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { state.showGeneralSettings ? -1 : state.selectedRuleIndex },
                set: { newValue in
                    if newValue == -1 {
                        state.showGeneralSettings = true
                        state.selectedRuleIndex = nil
                    } else {
                        state.showGeneralSettings = false
                        state.selectedRuleIndex = newValue
                    }
                }
            )) {
                Section("App Rules") {
                    ForEach(Array(state.rules.enumerated()), id: \.offset) { index, rule in
                        let st = state.status(for: rule.name)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(st))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name.isEmpty ? "Untitled Rule" : rule.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Text("\(rule.mode) • \(rule.targetProcesses.count) target(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let pids = st?.targetPids, !pids.isEmpty {
                                Text("\(pids.count) running")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(index)
                    }
                }

                Section("Daemon & Logs") {
                    Label("General Settings", systemImage: "gearshape")
                        .tag(-1)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button(action: state.addRule) {
                    Image(systemName: "plus")
                }
                .help("Add new rule")

                Button(action: state.deleteSelectedRule) {
                    Image(systemName: "minus")
                }
                .disabled(state.selectedRuleIndex == nil || state.showGeneralSettings)
                .help("Delete selected rule")

                Spacer()

                Button(action: state.revealConfigInFinder) {
                    Image(systemName: "doc.text")
                }
                .help("Reveal config.json in Finder")
            }
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if let banner = state.statusBanner {
                HStack {
                    Image(systemName: state.isBannerError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(state.isBannerError ? .red : .green)
                    Text(banner)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(state.isBannerError ? Color.red.opacity(0.1) : Color.green.opacity(0.08))
                Divider()
            }

            if state.showGeneralSettings {
                GeneralSettingsView(state: state)
            } else if let idx = state.selectedRuleIndex, state.rules.indices.contains(idx) {
                RuleDetailView(
                    rule: Binding(
                        get: { state.rules[idx] },
                        set: { newRule in
                            var list = state.rules
                            list[idx] = newRule
                            state.rules = list
                        }
                    ),
                    status: state.status(for: state.rules[idx].name)
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Select a rule or click + to add one")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func statusColor(_ status: RuleStatus?) -> Color {
        guard let status = status else { return .gray }
        if status.bypassActive { return .orange }
        return status.blockedNow ? .red : .green
    }
}

// MARK: - Rule Detail View

private struct RuleDetailView: View {
    @Binding var rule: GuardRule
    let status: RuleStatus?

    private let modes = [
        ("hide", "Hide App (Non-destructive)"),
        ("kill", "Force Terminate (Kill)"),
        ("minimize", "Minimize Windows"),
        ("close_windows", "Close Windows")
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Rule Name", text: $rule.name)
                        .textFieldStyle(.roundedBorder)
                    if let status = status {
                        StatusBadge(status: status)
                    }
                }

                Picker("Enforcement Mode", selection: $rule.mode) {
                    ForEach(modes, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                Toggle("Always Block (24/7)", isOn: $rule.alwaysBlock)
            } header: {
                Text("Rule Overview")
            }

            if !rule.alwaysBlock {
                Section {
                    WindowListEditor(
                        title: "Allowed Windows (Whitelist)",
                        subtitle: "When non-empty, the app is ONLY allowed during these windows and blocked at all other times.",
                        windows: Binding(
                            get: { rule.allowedWindows ?? [] },
                            set: { rule.allowedWindows = $0.isEmpty ? nil : $0 }
                        )
                    )
                } header: {
                    Text("Allowed Schedule (Optional Whitelist)")
                }

                Section {
                    WindowListEditor(
                        title: "Blocked Windows (Blacklist)",
                        subtitle: "Used when Allowed Windows is empty. Supports overnight ranges (e.g. 23:00 → 08:00).",
                        windows: Binding(
                            get: { rule.blockedWindows ?? [] },
                            set: { rule.blockedWindows = $0.isEmpty ? nil : $0 }
                        )
                    )
                } header: {
                    Text("Blocked Schedule")
                }
            }

            Section {
                ProcessListEditor(
                    title: "Target Processes",
                    subtitle: "Exact executable name (e.g. LeagueClientUx) or path substring (e.g. Safari.app/Contents/MacOS/Safari).",
                    items: $rule.targetProcesses,
                    placeholder: "e.g. LeagueClientUx"
                )
            } header: {
                Text("Target Processes (Blocked / Hidden)")
            }

            Section {
                ProcessListEditor(
                    title: "Bypass Processes (Allow while running)",
                    subtitle: "If any of these processes are running, enforcement pauses (e.g. active League of Legends match).",
                    items: $rule.allowProcesses,
                    placeholder: "e.g. League of Legends"
                )
            } header: {
                Text("Bypass / Safe Processes")
            }

            if rule.mode.lowercased() == "kill" {
                Section {
                    ProcessListEditor(
                        title: "Also Kill Processes",
                        subtitle: "Optional extra helper processes to terminate alongside targets when mode is Kill.",
                        items: Binding(
                            get: { rule.alsoKillProcesses ?? [] },
                            set: { rule.alsoKillProcesses = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "e.g. LeagueClient"
                    )
                } header: {
                    Text("Extra Processes to Kill")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StatusBadge: View {
    let status: RuleStatus

    var body: some View {
        let (text, color): (String, Color) = {
            if status.bypassActive { return ("Bypass Active", .orange) }
            if status.blockedNow { return ("Blocked Now", .red) }
            return ("Allowed Now", .green)
        }()

        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

// MARK: - Time Window Editor

private struct WindowListEditor: View {
    let title: String
    let subtitle: String
    @Binding var windows: [TimeWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(windows.enumerated()), id: \.offset) { idx, _ in
                TimeWindowRow(
                    window: $windows[idx],
                    onDelete: { windows.remove(at: idx) }
                )
            }

            Button {
                windows.append(TimeWindow(days: nil, start: "23:00", end: "08:00"))
            } label: {
                Label("Add Time Window", systemImage: "plus.circle")
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 4)
    }
}

private struct TimeWindowRow: View {
    @Binding var window: TimeWindow
    let onDelete: () -> Void

    private static let allDays: [(key: String, label: String)] = [
        ("mon", "M"), ("tue", "T"), ("wed", "W"), ("thu", "T"),
        ("fri", "F"), ("sat", "S"), ("sun", "S")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DatePicker(
                    "Start",
                    selection: timeBinding(for: \.start),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()

                Text("→")
                    .foregroundStyle(.secondary)

                DatePicker(
                    "End",
                    selection: timeBinding(for: \.end),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()

                Spacer()

                HStack(spacing: 3) {
                    ForEach(Self.allDays, id: \.key) { day in
                        let selected = (window.days ?? []).contains { $0.lowercased() == day.key }
                        Button {
                            toggleDay(day.key)
                        } label: {
                            Text(day.label)
                                .font(.caption2.bold())
                                .frame(width: 22, height: 22)
                                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                                .foregroundStyle(selected ? .white : .primary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(day.key.uppercased())
                    }
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            Text((window.days?.isEmpty ?? true) ? "Active every day" : "Days: \((window.days ?? []).joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toggleDay(_ key: String) {
        var current = (window.days ?? []).map { $0.lowercased() }
        if let idx = current.firstIndex(of: key) {
            current.remove(at: idx)
        } else {
            current.append(key)
        }
        let order = Self.allDays.map(\.key)
        current.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        window.days = current.isEmpty ? nil : current
    }

    private func timeBinding(for keyPath: WritableKeyPath<TimeWindow, String>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let value = window[keyPath: keyPath]
                let parts = value.split(separator: ":")
                let hour = parts.count == 2 ? (Int(parts[0]) ?? 0) : 0
                let minute = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = hour
                comps.minute = minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                let h = comps.hour ?? 0
                let m = comps.minute ?? 0
                window[keyPath: keyPath] = String(format: "%02d:%02d", h, m)
            }
        )
    }
}

// MARK: - Process List & Picker

private struct ProcessListEditor: View {
    let title: String
    let subtitle: String
    @Binding var items: [String]
    let placeholder: String

    @State private var newEntry: String = ""
    @State private var showingPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        items.remove(at: idx)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                TextField(placeholder, text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTypedEntry)

                Button("Add", action: addTypedEntry)
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Pick Running App...") {
                    showingPicker = true
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingPicker) {
            RunningProcessPickerSheet { selectedPattern in
                if !items.contains(selectedPattern) {
                    items.append(selectedPattern)
                }
            }
        }
    }

    private func addTypedEntry() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !items.contains(trimmed) {
            items.append(trimmed)
        }
        newEntry = ""
    }
}

private struct RunningProcessPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (String) -> Void

    @State private var query: String = ""
    @State private var useFullPath: Bool = true
    @State private var apps: [RunningAppInfo] = []

    var filteredApps: [RunningAppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            ($0.executablePath?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Select a Running Application")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack {
                TextField("Search running apps...", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Use Full Path", isOn: $useFullPath)
                    .help("Full path is safer for Electron/helper apps; executable name is shorter.")
            }

            List(filteredApps) { app in
                Button {
                    let pattern = (useFullPath ? app.executablePath : app.executableName) ?? app.name
                    onSelect(pattern)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        if let path = app.executablePath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .padding()
        .frame(width: 540, height: 420)
        .onAppear {
            apps = listRunningGUIApps()
        }
    }
}

// MARK: - General Settings View

private struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Background Service") {
                HStack {
                    Text("launchd Agent (com.lolguard.agent)")
                    Spacer()
                    Text(state.isLaunchdAgentLoaded ? "Running" : "Not Loaded")
                        .foregroundStyle(state.isLaunchdAgentLoaded ? .green : .secondary)
                }

                Toggle("Run Guard Inside This App", isOn: Binding(
                    get: { state.isInAppGuardRunning },
                    set: { _ in state.toggleInAppGuard() }
                ))

                Toggle("Launch GUI at Login", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { _ in state.toggleLaunchAtLogin() }
                ))
            }

            Section("Polling & Logging") {
                HStack {
                    Text("Active Poll Interval (seconds)")
                    Spacer()
                    TextField("", value: Binding(
                        get: { state.config.activePollIntervalSeconds ?? 0.5 },
                        set: { state.config.activePollIntervalSeconds = $0; state.hasUnsavedChanges = true }
                    ), format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Idle Heartbeat (seconds)")
                    Spacer()
                    TextField("", value: Binding(
                        get: { state.config.idleHeartbeatSeconds ?? 30.0 },
                        set: { state.config.idleHeartbeatSeconds = $0; state.hasUnsavedChanges = true }
                    ), format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                }

                TextField("Log File Path", text: Binding(
                    get: { state.config.logFile ?? "~/Library/Logs/lol-guard.log" },
                    set: { state.config.logFile = $0.isEmpty ? nil : $0; state.hasUnsavedChanges = true }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Section("Configuration File") {
                HStack {
                    Text(state.configPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder", action: state.revealConfigInFinder)
                }
            }
        }
        .formStyle(.grouped)
    }
}
