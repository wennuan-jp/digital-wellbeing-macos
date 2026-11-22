import Foundation

public final class Logger {
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public var logFilePath: String?
    public var maxLogBytes: UInt64 = 1_048_576

    public init() {}

    public func log(_ message: String) {
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
