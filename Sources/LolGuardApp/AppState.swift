import AppKit
import Foundation
import GuardCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var config: Config
    @Published var selectedRuleIndex: Int? = 0
    @Published var showGeneralSettings: Bool = false
    @Published var statuses: [RuleStatus] = []
    @Published var hasUnsavedChanges: Bool = false
    @Published var statusBanner: String?
    @Published var isBannerError: Bool = false
    @Published var isInAppGuardRunning: Bool = false
    @Published var isLaunchdAgentLoaded: Bool = false
    @Published var launchAtLoginEnabled: Bool = false

    let configPath: String
    private var refreshTimer: Timer?
    private var inAppGuard: LoLGuard?

    init(configPath: String = defaultConfigPath()) {
        self.configPath = configPath
        self.config = Config()
        loadConfig()
        refreshStatuses()
        refreshServiceStates()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatuses()
            }
        }
    }

    var rules: [GuardRule] {
        get { config.rules ?? config.effectiveRules }
        set {
            config.rules = newValue
            hasUnsavedChanges = true
        }
    }

    func loadConfig() {
        let fm = FileManager.default
        if fm.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var decoded = try JSONDecoder().decode(Config.self, from: data)
                if decoded.rules == nil || decoded.rules?.isEmpty == true {
                    decoded.rules = decoded.effectiveRules
                }
                self.config = decoded
                self.hasUnsavedChanges = false
                if let count = decoded.rules?.count, count > 0 {
                    if selectedRuleIndex == nil || (selectedRuleIndex ?? 0) >= count {
                        selectedRuleIndex = 0
                    }
                } else {
                    selectedRuleIndex = nil
                }
                setBanner("Loaded \(configPath)", isError: false)
            } catch {
                setBanner("Failed to load config: \(error.localizedDescription)", isError: true)
            }
        } else {
            var initial = Config()
            initial.rules = initial.effectiveRules
            initial.activePollIntervalSeconds = 0.5
            initial.idleHeartbeatSeconds = 30.0
            initial.logFile = "~/Library/Logs/lol-guard.log"
            initial.maxLogBytes = 1_048_576
            self.config = initial
            self.hasUnsavedChanges = false
            self.selectedRuleIndex = 0
            setBanner("Using default rules (not yet saved to \(configPath))", isError: false)
        }
    }

    func saveConfig() {
        do {
            var toSave = config
            if toSave.rules == nil || toSave.rules?.isEmpty == true {
                toSave.rules = rules
            }
            // Clear legacy top-level single-rule fields once saved via multi-rule GUI
            toSave.mode = nil
            toSave.alwaysBlock = nil
            toSave.allowedWindows = nil
            toSave.blockedWindows = nil
            toSave.gameProcesses = nil
            toSave.lobbyProcesses = nil
            toSave.alsoKillLeagueClient = nil

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(toSave)

            let url = URL(fileURLWithPath: configPath)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)

            self.config = toSave
            self.hasUnsavedChanges = false
            setBanner("Saved! Running guard will auto-reload.", isError: false)
            refreshStatuses()
        } catch {
            setBanner("Failed to save config: \(error.localizedDescription)", isError: true)
        }
    }

    func addRule() {
        var list = rules
        let newRule = GuardRule(
            name: "New App Rule \(list.count + 1)",
            mode: "hide",
            alwaysBlock: false,
            allowedWindows: nil,
            blockedWindows: [TimeWindow(days: nil, start: "23:00", end: "08:00")],
            allowProcesses: [],
            targetProcesses: []
        )
        list.append(newRule)
        rules = list
        showGeneralSettings = false
        selectedRuleIndex = list.count - 1
    }

    func deleteSelectedRule() {
        guard let idx = selectedRuleIndex, rules.indices.contains(idx) else { return }
        var list = rules
        list.remove(at: idx)
        rules = list
        if list.isEmpty {
            selectedRuleIndex = nil
        } else {
            selectedRuleIndex = min(idx, list.count - 1)
        }
    }

    func refreshStatuses() {
        let procs = listUserProcesses()
        let now = Date()
        statuses = rules.map { rule in
            let bypassRunning = !rule.allowProcesses.isEmpty && procs.contains { matchesProcess($0, patterns: rule.allowProcesses) }
            let targetPids = procs.filter { matchesProcess($0, patterns: rule.targetProcesses) }.map { $0.pid }
            let blocked = isWithinBlockedSchedule(
                alwaysBlock: rule.alwaysBlock,
                allowedWindows: rule.allowedWindows,
                blockedWindows: rule.blockedWindows,
                now: now
            )
            return RuleStatus(
                name: rule.name,
                mode: rule.mode,
                alwaysBlock: rule.alwaysBlock,
                blockedNow: blocked,
                bypassActive: bypassRunning,
                targetPids: targetPids
            )
        }
    }

    func status(for ruleName: String) -> RuleStatus? {
        statuses.first { $0.name == ruleName }
    }

    func toggleInAppGuard() {
        if isInAppGuardRunning {
            inAppGuard?.stopDaemon()
            inAppGuard = nil
            isInAppGuardRunning = false
            setBanner("In-app guard stopped.", isError: false)
        } else {
            if hasUnsavedChanges {
                saveConfig()
            }
            let daemon = LoLGuard(configPath: configPath, dryRun: false)
            daemon.startDaemon()
            inAppGuard = daemon
            isInAppGuardRunning = true
            setBanner("In-app guard started.", isError: false)
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshServiceStates()
        } catch {
            setBanner("Launch at Login error: \(error.localizedDescription)", isError: true)
        }
    }

    func refreshServiceStates() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/com.lolguard.agent"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            isLaunchdAgentLoaded = (task.terminationStatus == 0)
        } catch {
            isLaunchdAgentLoaded = false
        }
    }

    func revealConfigInFinder() {
        let url = URL(fileURLWithPath: configPath)
        if FileManager.default.fileExists(atPath: configPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func setBanner(_ message: String, isError: Bool) {
        statusBanner = message
        isBannerError = isError
    }
}
