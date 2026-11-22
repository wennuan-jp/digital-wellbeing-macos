import Foundation

public struct TimeWindow: Codable, Equatable, Hashable {
    /// Optional days of week: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]. Empty/nil means every day.
    public var days: [String]?
    public var start: String // "HH:mm"
    public var end: String   // "HH:mm"

    public init(days: [String]? = nil, start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }
}

public struct GuardRule: Codable, Equatable, Hashable {
    public var name: String
    public var mode: String
    public var alwaysBlock: Bool
    public var allowedWindows: [TimeWindow]?
    public var blockedWindows: [TimeWindow]?
    /// Processes that, if running, pause enforcement for this rule (e.g. ["League of Legends"])
    public var allowProcesses: [String]
    /// Target processes to hide/kill (matches exact executable name OR substring of full executable path)
    public var targetProcesses: [String]
    /// Optional extra processes to terminate when mode == "kill"
    public var alsoKillProcesses: [String]?

    public init(
        name: String,
        mode: String = "hide",
        alwaysBlock: Bool = false,
        allowedWindows: [TimeWindow]? = nil,
        blockedWindows: [TimeWindow]? = nil,
        allowProcesses: [String] = [],
        targetProcesses: [String] = [],
        alsoKillProcesses: [String]? = nil
    ) {
        self.name = name
        self.mode = mode
        self.alwaysBlock = alwaysBlock
        self.allowedWindows = allowedWindows
        self.blockedWindows = blockedWindows
        self.allowProcesses = allowProcesses
        self.targetProcesses = targetProcesses
        self.alsoKillProcesses = alsoKillProcesses
    }

    enum CodingKeys: String, CodingKey {
        case name, mode, alwaysBlock, allowedWindows, blockedWindows, allowProcesses, targetProcesses, alsoKillProcesses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "hide"
        self.alwaysBlock = try c.decodeIfPresent(Bool.self, forKey: .alwaysBlock) ?? false
        self.allowedWindows = try c.decodeIfPresent([TimeWindow].self, forKey: .allowedWindows)
        self.blockedWindows = try c.decodeIfPresent([TimeWindow].self, forKey: .blockedWindows)
        self.allowProcesses = try c.decodeIfPresent([String].self, forKey: .allowProcesses) ?? []
        self.targetProcesses = try c.decodeIfPresent([String].self, forKey: .targetProcesses) ?? []
        self.alsoKillProcesses = try c.decodeIfPresent([String].self, forKey: .alsoKillProcesses)
    }
}

public struct Config: Codable, Equatable {
    /// Multi-app rules. If non-empty, overrides the legacy single-rule top-level fields below.
    public var rules: [GuardRule]?
    /// Legacy single-rule fields (optional when `rules` is provided)
    public var mode: String?
    public var alwaysBlock: Bool?
    public var allowedWindows: [TimeWindow]?
    public var blockedWindows: [TimeWindow]?
    public var gameProcesses: [String]?
    public var lobbyProcesses: [String]?
    public var alsoKillLeagueClient: Bool?
    /// Polling interval (seconds) while target process is actively running
    public var activePollIntervalSeconds: Double?
    /// Fallback heartbeat interval (seconds) when idle (NSWorkspace notifications handle instant wakeups)
    public var idleHeartbeatSeconds: Double?
    /// Log file path (optional; stdout/stderr used if nil or empty)
    public var logFile: String?
    /// Max log file size in bytes before truncating/rotating (default 1 MB)
    public var maxLogBytes: UInt64?

    public init(
        rules: [GuardRule]? = nil,
        mode: String? = nil,
        alwaysBlock: Bool? = nil,
        allowedWindows: [TimeWindow]? = nil,
        blockedWindows: [TimeWindow]? = nil,
        gameProcesses: [String]? = nil,
        lobbyProcesses: [String]? = nil,
        alsoKillLeagueClient: Bool? = nil,
        activePollIntervalSeconds: Double? = nil,
        idleHeartbeatSeconds: Double? = nil,
        logFile: String? = nil,
        maxLogBytes: UInt64? = nil
    ) {
        self.rules = rules
        self.mode = mode
        self.alwaysBlock = alwaysBlock
        self.allowedWindows = allowedWindows
        self.blockedWindows = blockedWindows
        self.gameProcesses = gameProcesses
        self.lobbyProcesses = lobbyProcesses
        self.alsoKillLeagueClient = alsoKillLeagueClient
        self.activePollIntervalSeconds = activePollIntervalSeconds
        self.idleHeartbeatSeconds = idleHeartbeatSeconds
        self.logFile = logFile
        self.maxLogBytes = maxLogBytes
    }

    public var effectiveActivePollInterval: Double { activePollIntervalSeconds ?? 0.5 }
    public var effectiveIdleHeartbeat: Double { idleHeartbeatSeconds ?? 30.0 }

    public var effectiveRules: [GuardRule] {
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

public func defaultConfigPath() -> String {
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
