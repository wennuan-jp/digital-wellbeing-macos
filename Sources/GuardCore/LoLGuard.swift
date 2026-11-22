import AppKit
import Darwin
import Foundation

public struct RuleStatus: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let mode: String
    public let alwaysBlock: Bool
    public let blockedNow: Bool
    public let bypassActive: Bool
    public let targetPids: [pid_t]

    public init(
        name: String,
        mode: String,
        alwaysBlock: Bool,
        blockedNow: Bool,
        bypassActive: Bool,
        targetPids: [pid_t]
    ) {
        self.name = name
        self.mode = mode
        self.alwaysBlock = alwaysBlock
        self.blockedNow = blockedNow
        self.bypassActive = bypassActive
        self.targetPids = targetPids
    }
}

public final class LoLGuard {
    public let configPath: String
    public let dryRun: Bool
    private let logger = Logger()
    public private(set) var config = Config()
    private var lastConfigMtime: Date?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var currentInterval: Double = 0
    private var activeBypassRules: Set<String> = []

    public init(configPath: String, dryRun: Bool = false) {
        self.configPath = (configPath as NSString).expandingTildeInPath
        self.dryRun = dryRun
        reloadConfigIfNeeded(force: true)
    }

    public func reloadConfigIfNeeded(force: Bool = false) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else {
            if force {
                logger.log("Config not found at \(configPath), using built-in defaults.")
            }
            return
        }

        let attrs = try? fm.attributesOfItem(atPath: configPath)
        let mtime = attrs?[.modificationDate] as? Date
        if !force, let mtime = mtime, mtime == lastConfigMtime {
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            self.config = decoded
            self.lastConfigMtime = mtime
            self.logger.logFilePath = decoded.logFile
            self.logger.maxLogBytes = decoded.maxLogBytes ?? 1_048_576
            logger.log("Loaded config from \(configPath) (rules=\(decoded.effectiveRules.count)).")
        } catch {
            logger.log("Failed to parse config at \(configPath): \(error). Keeping previous config.")
        }
    }

    public func currentStatuses(now: Date = Date()) -> [RuleStatus] {
        reloadConfigIfNeeded(force: true)
        let procs = listUserProcesses()
        return config.effectiveRules.map { rule in
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

    public func printStatus() {
        let statuses = currentStatuses()
        print("LoL Guard Status (config: \(configPath))")
        for status in statuses {
            print("  Rule: \(status.name)")
            print("    Mode:            \(status.mode)")
            print("    Always block:    \(status.alwaysBlock)")
            print("    Blocked now:     \(status.blockedNow)")
            print("    Bypass active:   \(status.bypassActive)")
            print("    Target PIDs:     \(status.targetPids.isEmpty ? "none" : status.targetPids.map(String.init).joined(separator: ", "))")
        }
    }

    /// Evaluates all rules against current processes and returns the recommended next polling interval.
    @discardableResult
    public func evaluateOnce() -> Double {
        reloadConfigIfNeeded()

        let procs = listUserProcesses()
        var nextInterval = config.effectiveIdleHeartbeat

        for rule in config.effectiveRules {
            let interval = evaluateRule(rule, procs: procs)
            nextInterval = min(nextInterval, interval)
        }
        return nextInterval
    }

    private func evaluateRule(_ rule: GuardRule, procs: [ProcessInfoEntry]) -> Double {
        let bypassActive = !rule.allowProcesses.isEmpty && procs.contains { matchesProcess($0, patterns: rule.allowProcesses) }
        if bypassActive {
            if !activeBypassRules.contains(rule.name) {
                logger.log("[\(rule.name)] Bypass process active (\(rule.allowProcesses.joined(separator: "/"))). Allowing without interruption.")
                activeBypassRules.insert(rule.name)
            }
            return min(5.0, config.effectiveIdleHeartbeat)
        } else if activeBypassRules.contains(rule.name) {
            logger.log("[\(rule.name)] Bypass process ended.")
            activeBypassRules.remove(rule.name)
        }

        let targets = procs.filter { matchesProcess($0, patterns: rule.targetProcesses) }
        guard !targets.isEmpty else {
            return config.effectiveIdleHeartbeat
        }

        let blocked = isWithinBlockedSchedule(
            alwaysBlock: rule.alwaysBlock,
            allowedWindows: rule.allowedWindows,
            blockedWindows: rule.blockedWindows
        )
        guard blocked else {
            return config.effectiveIdleHeartbeat
        }

        let mode = rule.mode.lowercased()
        switch mode {
        case "kill":
            var killTargets = targets
            if let extra = rule.alsoKillProcesses, !extra.isEmpty {
                killTargets.append(contentsOf: procs.filter { matchesProcess($0, patterns: extra) })
            }
            for proc in killTargets {
                if dryRun {
                    logger.log("[\(rule.name)] [DRY-RUN] Would terminate \(proc.name) (pid=\(proc.pid))")
                } else {
                    terminateProcess(pid: proc.pid, name: proc.name)
                }
            }
        case "minimize":
            for proc in targets {
                if dryRun {
                    logger.log("[\(rule.name)] [DRY-RUN] Would minimize windows of \(proc.name) (pid=\(proc.pid))")
                } else {
                    minimizeWindows(pid: proc.pid, name: proc.name, ruleName: rule.name)
                }
            }
        case "close_windows", "close-windows", "closewindows":
            for proc in targets {
                if dryRun {
                    logger.log("[\(rule.name)] [DRY-RUN] Would close windows of \(proc.name) (pid=\(proc.pid))")
                } else {
                    closeWindows(pid: proc.pid, name: proc.name, ruleName: rule.name)
                }
            }
        default:
            for proc in targets {
                if dryRun {
                    logger.log("[\(rule.name)] [DRY-RUN] Would hide \(proc.name) (pid=\(proc.pid))")
                } else {
                    hideProcess(pid: proc.pid, name: proc.name)
                }
            }
        }
        return config.effectiveActivePollInterval
    }

    private func closeWindows(pid: pid_t, name: String, ruleName: String) {
        let count = runWindowAppleScript(pid: pid, name: name, ruleName: ruleName) { target in
            """
            tell \(target)
                set winCount to count of windows
                if winCount > 0 then
                    close every window
                end if
                return winCount
            end tell
            """
        }
        if let count = count, count > 0 {
            logger.log("[\(ruleName)] Closed \(count) window(s) of \(name) (pid=\(pid)).")
        }
    }

    private func minimizeWindows(pid: pid_t, name: String, ruleName: String) {
        let count = runWindowAppleScript(pid: pid, name: name, ruleName: ruleName) { target in
            """
            tell \(target)
                set minCount to 0
                repeat with w in windows
                    if miniaturized of w is false then
                        set miniaturized of w to true
                        set minCount to minCount + 1
                    end if
                end repeat
                return minCount
            end tell
            """
        }
        if let count = count, count > 0 {
            logger.log("[\(ruleName)] Minimized \(count) window(s) of \(name) (pid=\(pid)).")
        }
    }

    private func runWindowAppleScript(pid: pid_t, name: String, ruleName: String, buildScript: (String) -> String) -> Int? {
        let app = NSRunningApplication(processIdentifier: pid)
            ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        let targetExpr: String
        if let bundleId = app?.bundleIdentifier, !bundleId.isEmpty {
            let escaped = bundleId.replacingOccurrences(of: "\"", with: "\\\"")
            targetExpr = "application id \"\(escaped)\""
        } else {
            let appName = (app?.localizedName ?? name).replacingOccurrences(of: "\"", with: "\\\"")
            targetExpr = "application \"\(appName)\""
        }

        let source = buildScript(targetExpr)
        guard let script = NSAppleScript(source: source) else {
            logger.log("[\(ruleName)] Failed to initialize AppleScript for \(name) (pid=\(pid)); falling back to hide.")
            hideProcess(pid: pid, name: name)
            return nil
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let errNum = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let errMsg = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if errNum == -1743 {
                logger.log("[\(ruleName)] Automation permission denied for \(name) (-1743). Grant access in System Settings > Privacy & Security > Automation. Falling back to hide.")
            } else {
                logger.log("[\(ruleName)] AppleScript error for \(name) (pid=\(pid), code=\(errNum)): \(errMsg). Falling back to hide.")
            }
            hideProcess(pid: pid, name: name)
            return nil
        }
        return Int(result.int32Value)
    }

    private func hideProcess(pid: pid_t, name: String) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if !app.isHidden {
                let ok = app.hide()
                logger.log("Hid \(name) (pid=\(pid), success=\(ok)).")
            }
        } else {
            for app in NSWorkspace.shared.runningApplications where app.processIdentifier == pid {
                if !app.isHidden {
                    let ok = app.hide()
                    logger.log("Hid \(name) via NSWorkspace (pid=\(pid), success=\(ok)).")
                }
            }
        }
    }

    private func terminateProcess(pid: pid_t, name: String) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let ok = app.forceTerminate()
            logger.log("Force-terminated \(name) via NSRunningApplication (pid=\(pid), success=\(ok)).")
            if ok { return }
        }
        let rc = Darwin.kill(pid, SIGTERM)
        if rc == 0 {
            logger.log("Sent SIGTERM to \(name) (pid=\(pid)).")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if Darwin.kill(pid, 0) == 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                    self.logger.log("Sent SIGKILL to \(name) (pid=\(pid)).")
                }
            }
        } else {
            logger.log("Failed to terminate \(name) (pid=\(pid), errno=\(errno)).")
        }
    }

    public func startDaemon() {
        stopDaemon()
        logger.log("LoL Guard daemon started (pid=\(getpid()), dryRun=\(dryRun)).")

        let nc = NSWorkspace.shared.notificationCenter
        let trigger: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            let nextInterval = self.evaluateOnce()
            self.rescheduleTimer(interval: nextInterval)
        }

        observers = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: trigger),
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: trigger),
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: trigger)
        ]

        let initialInterval = evaluateOnce()
        rescheduleTimer(interval: initialInterval)
    }

    public func stopDaemon() {
        timer?.cancel()
        timer = nil
        currentInterval = 0
        let nc = NSWorkspace.shared.notificationCenter
        for obs in observers {
            nc.removeObserver(obs)
        }
        observers.removeAll()
    }

    private func rescheduleTimer(interval: Double) {
        let clamped = max(0.25, interval)
        if abs(clamped - currentInterval) < 0.05, timer != nil {
            return
        }
        currentInterval = clamped
        timer?.cancel()

        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + clamped, repeating: clamped, leeway: .milliseconds(100))
        newTimer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let next = self.evaluateOnce()
            self.rescheduleTimer(interval: next)
        }
        newTimer.resume()
        self.timer = newTimer
    }
}
