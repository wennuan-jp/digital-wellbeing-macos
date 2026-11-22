import Foundation

public func parseMinutes(_ hhmm: String) -> Int? {
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

public func parseWeekday(_ token: String) -> Int? {
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

public func matchesWindow(_ window: TimeWindow, weekday: Int, currentMinutes: Int) -> Bool {
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

public func isWithinBlockedSchedule(
    alwaysBlock: Bool,
    allowedWindows: [TimeWindow]?,
    blockedWindows: [TimeWindow]?,
    now: Date = Date()
) -> Bool {
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
