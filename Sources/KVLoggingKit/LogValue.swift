import Foundation

public enum LogValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case null

    public var stringValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .double(value): String(value)
        case let .boolean(value): String(value)
        case .null: "null"
        }
    }
}

public enum LogFieldPrivacy: String, Codable, Sendable {
    case `public`
    case `private`
}

public struct LogField: Codable, Equatable, Sendable {
    public let value: LogValue
    public let privacy: LogFieldPrivacy

    public init(value: LogValue, privacy: LogFieldPrivacy) {
        self.value = value
        self.privacy = privacy
    }

    public static func `public`(_ value: String) -> Self {
        .init(value: .string(value), privacy: .public)
    }

    public static func `public`(_ value: Int) -> Self {
        .init(value: .integer(value), privacy: .public)
    }

    public static func `public`(_ value: Double) -> Self {
        .init(value: .double(value), privacy: .public)
    }

    public static func `public`(_ value: Bool) -> Self {
        .init(value: .boolean(value), privacy: .public)
    }

    public static func `public`(_ value: UUID) -> Self {
        .public(value.uuidString)
    }

    public static func `private`(_ value: String) -> Self {
        .init(value: .string(value), privacy: .private)
    }

    public static func `private`(_ value: Int) -> Self {
        .init(value: .integer(value), privacy: .private)
    }

    public static func `private`(_ value: Double) -> Self {
        .init(value: .double(value), privacy: .private)
    }

    public static func `private`(_ value: Bool) -> Self {
        .init(value: .boolean(value), privacy: .private)
    }

    public static func `private`(_ value: UUID) -> Self {
        .private(value.uuidString)
    }
}

public typealias LogMetadata = [String: LogField]
