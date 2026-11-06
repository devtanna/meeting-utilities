import Foundation

/// Versioned JSON contract with the "Meeting Utility: Focus until end" Shortcut (§12.1).
public struct FocusShortcutInput: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var requestID: String
    public var deadline: String          // ISO-8601, e.g. 2026-11-05T10:30:00Z
    public var deadlineEpoch: Int
    public var minutesUntilDeadline: Int

    public init(requestID: UUID, deadline: Date, now: Date) {
        self.requestID = requestID.uuidString
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        self.deadline = f.string(from: deadline)
        self.deadlineEpoch = Int(deadline.timeIntervalSince1970)
        self.minutesUntilDeadline = max(0, Int(ceil(deadline.timeIntervalSince(now) / 60)))
    }
}

public enum FocusResult: Sendable, Equatable {
    case enabledUntil(Date?)
    case preservedExisting
    case failed(String)
    case notConfigured
    case disabled

    public var userMessage: String {
        switch self {
        case .enabledUntil: "Do Not Disturb on until the scheduled end"
        case .preservedExisting: "Existing Focus preserved"
        case .failed: "Focus unchanged (Shortcut failed)"
        case .notConfigured: "Focus Shortcut not set up"
        case .disabled: "Auto Focus off"
        }
    }
}

public enum FocusPolicy {
    public static let maximumDuration: TimeInterval = 12 * 3600

    public static func validate(deadline: Date, now: Date) -> Bool {
        deadline > now && deadline.timeIntervalSince(now) <= maximumDuration
    }

    /// Parses the Shortcut's output. Anything unrecognized is a failure, which means "make no change" (§12.3).
    public static func parse(output: String) -> FocusResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = (obj["status"] as? String ?? obj["result"] as? String)?.lowercased() {
            switch status {
            case "enabled_until":
                let until = (obj["until"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                return .enabledUntil(until)
            case "preserved_existing": return .preservedExisting
            default: return .failed(status)
            }
        }
        switch trimmed.lowercased() {
        case "enabled_until": return .enabledUntil(nil)
        case "preserved_existing": return .preservedExisting
        default: return .failed(trimmed.isEmpty ? "empty_output" : "unrecognized_output")
        }
    }
}

public protocol FocusController: Sendable {
    func enableIfNoFocus(until: Date, sessionID: UUID) async -> FocusResult
}
