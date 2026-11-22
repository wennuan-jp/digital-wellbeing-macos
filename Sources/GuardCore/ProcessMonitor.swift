import AppKit
import Darwin
import Foundation

public struct ProcessInfoEntry: Identifiable, Hashable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let fullPath: String

    public init(pid: pid_t, name: String, fullPath: String) {
        self.pid = pid
        self.name = name
        self.fullPath = fullPath
    }
}

public struct RunningAppInfo: Identifiable, Hashable {
    public var id: String { "\(pid)-\(executablePath ?? name)" }
    public let pid: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let executableName: String?
    public let executablePath: String?
}

public func matchesProcess(_ proc: ProcessInfoEntry, patterns: [String]) -> Bool {
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
public func listUserProcesses() -> [ProcessInfoEntry] {
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

/// Lists user-facing running GUI apps for selection in the UI.
public func listRunningGUIApps() -> [RunningAppInfo] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app in
            let execURL = app.executableURL
            let name = app.localizedName ?? execURL?.lastPathComponent ?? "Unknown"
            return RunningAppInfo(
                pid: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                executableName: execURL?.lastPathComponent,
                executablePath: execURL?.path
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
