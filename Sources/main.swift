import AppKit
import Darwin
import Foundation

// MARK: - Configuration

struct TimeWindow: Codable {
    /// Optional days of week: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]. Empty/nil means every day.
    var days: [String]? = nil
    let start: String // "HH:mm"
    let end: String   // "HH:mm"
}

struct GuardRule: Codable {
    var name: String
    var mode: String = "hide"
    var alwaysBlock: Bool = false
    var allowedWindows: [TimeWindow]? = nil
    var blockedWindows: [TimeWindow]? = nil
    /// Processes that, if running, pause enforcement for this rule (e.g. ["League of Legends"])
    var allowProcesses: [String] = []
    /// Target processes to hide/kill (matches exact executable name OR substring of full executable path)
    var targetProcesses: [String]
    /// Optional extra processes to terminate when mode == "kill"
    var alsoKillProcesses: [String]? = nil
}

struct Config: Codable {
    /// Multi-app rules. If non-empty, overrides the legacy single-rule top-level fields below.
    var rules: [GuardRule]? = nil
    /// Legacy single-rule fields (optional when `rules` is provided)
    var mode: String? = nil
    var alwaysBlock: Bool? = nil
    var allowedWindows: [TimeWindow]? = nil
    var blockedWindows: [TimeWindow]? = nil
    var gameProcesses: [String]? = nil
    var lobbyProcesses: [String]? = nil
    var alsoKillLeagueClient: Bool? = nil
    /// Polling interval (seconds) while target process is actively running
    var activePollIntervalSeconds: Double? = nil
    /// Fallback heartbeat interval (seconds) when idle (NSWorkspace notifications handle instant wakeups)
    var idleHeartbeatSeconds: Double? = nil
    /// Log file path (optional; stdout/stderr used if nil or empty)
    var logFile: String? = nil
    /// Max log file size in bytes before truncating/rotating (default 1 MB)
    var maxLogBytes: UInt64? = nil

    var effectiveActivePollInterval: Double { activePollIntervalSeconds ?? 0.5 }
    var effectiveIdleHeartbeat: Double { idleHeartbeatSeconds ?? 30.0 }

    var effectiveRules: [GuardRule] {
        if let rules = rules, !rules.isEmpty {
            return rules
        }
        return [
            GuardRule(
                name: "League of Legends",
                mode: mode ?? "hide",
                alwaysBlock: alwaysBlock ?? false,
                allowedWindows: allowedWindows,
                blockedWindows: blockedWindows ?? [TimeWindow(days: nil, start: "23:00", end: "08:00")],
                allowProcesses: gameProcesses ?? ["League of Legends"],
                targetProcesses: lobbyProcesses ?? ["LeagueClientUx"],
                alsoKillProcesses: (alsoKillLeagueClient ?? false) ? ["LeagueClient"] : nil
            )
        ]
    }
}

// MARK: - Process Inspection (Zero Special Permissions)

struct ProcessInfoEntry {
    let pid: pid_t
    let name: String
    let fullPath: String
}

func matchesProcess(_ proc: ProcessInfoEntry, patterns: [String]) -> Bool {
    for pattern in patterns {
        if pattern.contains("/") {
            if proc.fullPath.contains(pattern) { return true }
        } else {
            if proc.name == pattern { return true }
        }
    }
    return false
}

/// Lists all processes accessible to the current user via libproc (no Accessibility/Screen Recording needed).
func listUserProcesses() -> [ProcessInfoEntry] {
    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount > 0 else { return [] }

    let capacity = Int(estimatedCount) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let byteSize = Int32(capacity * MemoryLayout<pid_t>.stride)
    let actualCount = Int(proc_listallpids(&pids, byteSize))
    guard actualCount > 0 else { return [] }

    var result: [ProcessInfoEntry] = []
    result.reserveCapacity(actualCount)

    // 4 * MAXPATHLEN (PROC_PIDPATHINFO_MAXSIZE = 4096)
    let pathBufferSize = 4096
    var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)

    for i in 0..<actualCount {
        let pid = pids[i]
        if pid <= 0 { continue }

        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBufferSize))
        if len > 0 {
            let fullPath = String(cString: pathBuffer)
            let name = (fullPath as NSString).lastPathComponent
            if !name.isEmpty {
                result.append(ProcessInfoEntry(pid: pid, name: name, fullPath: fullPath))
            }
        }
    }
    return result
}

// MARK: - Schedule Evaluation

func parseMinutes(_ hhmm: String) -> Int? {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1]),
          (0...23).contains(hour),
          (0...59).contains(minute) else {
        return nil
    }
    return hour * 60 + minute
}

func parseWeekday(_ token: String) -> Int? {
    switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "sun", "sunday": return 1
    case "mon", "monday": return 2
    case "tue", "tuesday": return 3
    case "wed", "wednesday": return 4
    case "thu", "thursday": return 5
    case "fri", "friday": return 6
    case "sat", "saturday": return 7
    default: return nil
    }
}

func matchesWindow(_ window: TimeWindow, weekday: Int, currentMinutes: Int) -> Bool {
    guard let start = parseMinutes(window.start),
          let end = parseMinutes(window.end) else { return false }

    let allowedDays: Set<Int>?
    if let days = window.days, !days.isEmpty {
        allowedDays = Set(days.compactMap(parseWeekday))
    } else {
        allowedDays = nil
    }

    let prevWeekday = weekday == 1 ? 7 : weekday - 1

    if start == end {
        return allowedDays?.contains(weekday) ?? true
    } else if start < end {
        let dayOK = allowedDays?.contains(weekday) ?? true
        return dayOK && currentMinutes >= start && currentMinutes < end
    } else {
        // Overnight range, e.g. 23:00 -> 08:00
        if currentMinutes >= start {
            return allowedDays?.contains(weekday) ?? true
        }
        if currentMinutes < end {
            return allowedDays?.contains(prevWeekday) ?? true
        }
        return false
    }
}

func isWithinBlockedSchedule(alwaysBlock: Bool, allowedWindows: [TimeWindow]?, blockedWindows: [TimeWindow]?, now: Date = Date()) -> Bool {
    if alwaysBlock { return true }

    let cal = Calendar.current
    let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
    guard let weekday = comps.weekday,
          let hour = comps.hour,
          let minute = comps.minute else { return false }
    let currentMinutes = hour * 60 + minute

    // Whitelist mode takes precedence if configured
    if let allowed = allowedWindows, !allowed.isEmpty {
        let isAllowed = allowed.contains { matchesWindow($0, weekday: weekday, currentMinutes: currentMinutes) }
        return !isAllowed
    }

    guard let blocked = blockedWindows, !blocked.isEmpty else { return false }
    return blocked.contains { matchesWindow($0, weekday: weekday, currentMinutes: currentMinutes) }
}

// MARK: - Logger

final class Logger {
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var logFilePath: String?
    var maxLogBytes: UInt64 = 1_048_576

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let path = logFilePath, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            rotateIfNeeded(path: expanded)
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: expanded),
                   let handle = FileHandle(forWritingAtPath: expanded) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    let dir = (expanded as NSString).deletingLastPathComponent
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? data.write(to: URL(fileURLWithPath: expanded))
                }
            }
        } else {
            fputs(line, stdout)
            fflush(stdout)
        }
    }

    private func rotateIfNeeded(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > maxLogBytes else { return }
        let backup = path + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: path, toPath: backup)
    }
}

// MARK: - Guard Daemon

final class LoLGuard {
    private let configPath: String
    private let dryRun: Bool
    private let logger = Logger()
    private var config = Config()
    private var lastConfigMtime: Date?
    private var timer: DispatchSourceTimer?
    private var currentInterval: Double = 0
    private var activeBypassRules: Set<String> = []

    init(configPath: String, dryRun: Bool) {
        self.configPath = (configPath as NSString).expandingTildeInPath
        self.dryRun = dryRun
        reloadConfigIfNeeded(force: true)
    }

    func reloadConfigIfNeeded(force: Bool = false) {
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

    func printStatus() {
        reloadConfigIfNeeded(force: true)
        let procs = listUserProcesses()

        print("LoL Guard Status (config: \(configPath))")
        for rule in config.effectiveRules {
            let bypassRunning = !rule.allowProcesses.isEmpty && procs.contains { matchesProcess($0, patterns: rule.allowProcesses) }
            let targetPids = procs.filter { matchesProcess($0, patterns: rule.targetProcesses) }.map { $0.pid }
            let blocked = isWithinBlockedSchedule(
                alwaysBlock: rule.alwaysBlock,
                allowedWindows: rule.allowedWindows,
                blockedWindows: rule.blockedWindows
            )
            print("  Rule: \(rule.name)")
            print("    Mode:            \(rule.mode)")
            print("    Always block:    \(rule.alwaysBlock)")
            print("    Blocked now:     \(blocked)")
            print("    Bypass active:   \(bypassRunning)")
            print("    Target PIDs:     \(targetPids.isEmpty ? "none" : targetPids.map(String.init).joined(separator: ", "))")
        }
    }

    /// Evaluates all rules against current processes and returns the recommended next polling interval.
    @discardableResult
    func evaluateOnce() -> Double {
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
            // Fallback: match via NSWorkspace runningApplications
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

    func startDaemon() {
        logger.log("LoL Guard daemon started (pid=\(getpid()), dryRun=\(dryRun)).")

        let nc = NSWorkspace.shared.notificationCenter
        let trigger: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            let nextInterval = self.evaluateOnce()
            self.rescheduleTimer(interval: nextInterval)
        }

        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: trigger)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: trigger)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: trigger)

        let initialInterval = evaluateOnce()
        rescheduleTimer(interval: initialInterval)
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

// MARK: - CLI Entrypoint

func defaultConfigPath() -> String {
    let homeConfig = ("~/.config/lol-guard/config.json" as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: homeConfig) {
        return homeConfig
    }
    let localConfig = FileManager.default.currentDirectoryPath + "/config.json"
    if FileManager.default.fileExists(atPath: localConfig) {
        return localConfig
    }
    return homeConfig
}

func printUsage() {
    print("""
    lol-guard - Lightweight 24/7 macOS League of Legends lobby guard

    Usage:
      lol-guard [options]

    Options:
      --config <path>   Path to JSON config (default: ~/.config/lol-guard/config.json)
      --once            Run a single check and exit
      --dry-run         Log actions without hiding or terminating processes
      --status          Print current status and exit
      --help, -h        Show this help message
    """)
}

var configPath = defaultConfigPath()
var runOnce = false
var dryRun = false
var showStatus = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--config":
        guard let val = args.next() else {
            fputs("Error: --config requires a path\n", stderr)
            exit(1)
        }
        configPath = val
    case "--once":
        runOnce = true
    case "--dry-run":
        dryRun = true
    case "--status":
        showStatus = true
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        fputs("Unknown argument: \(arg)\n", stderr)
        printUsage()
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let guardService = LoLGuard(configPath: configPath, dryRun: dryRun)

if showStatus {
    guardService.printStatus()
    exit(0)
}

if runOnce {
    guardService.evaluateOnce()
    exit(0)
}

guardService.startDaemon()
RunLoop.main.run()
