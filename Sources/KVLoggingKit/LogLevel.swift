public enum LogLevel: Int, CaseIterable, Codable, Sendable, Comparable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
