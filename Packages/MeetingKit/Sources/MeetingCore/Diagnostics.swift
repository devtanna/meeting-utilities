import Foundation
import os

/// OSLog categories (§22.3). Log only opaque IDs, counts, timings, codes, and state transitions.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.devtanna.meetingutils"
    public static let calendar = Logger(subsystem: subsystem, category: "calendar")
    public static let identity = Logger(subsystem: subsystem, category: "identity")
    public static let opening = Logger(subsystem: subsystem, category: "opening")
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    public static let focus = Logger(subsystem: subsystem, category: "focus")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let inference = Logger(subsystem: subsystem, category: "inference")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
    public static let models = Logger(subsystem: subsystem, category: "models")
    public static let app = Logger(subsystem: subsystem, category: "app")

    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}

/// Error catalogue with stable codes and plain messages (§22.2).
public enum AppErrorCode: String, Sendable, CaseIterable {
    case calendarDenied = "CAL-001"
    case calendarStale = "CAL-002"
    case linkMissing = "LNK-001"
    case openFailed = "LNK-002"
    case focusFailed = "FOC-001"
    case focusNotConfigured = "FOC-002"
    case speechModelMissing = "MDL-001"
    case summaryModelMissing = "MDL-002"
    case modelVerifyFailed = "MDL-003"
    case sourceFailed = "AUD-001"
    case micDenied = "AUD-002"
    case queueOverflow = "AUD-003"
    case inferenceCrashed = "INF-001"
    case databaseUnwritable = "DB-001"
    case databaseTooNew = "DB-002"
    case summaryInvalid = "SUM-001"
    case updateVerifyFailed = "UPD-001"
    case identityAmbiguous = "IDN-001"
    case sessionInterrupted = "SES-001"

    public var message: String {
        switch self {
        case .calendarDenied: "Calendar access is off. Upcoming meetings and automatic actions are paused."
        case .calendarStale: "Calendar data could not be refreshed. Showing the last known agenda; automatic actions are paused."
        case .linkMissing: "No supported meeting link was found for this event. Notes are still available."
        case .openFailed: "The meeting link could not be opened. Copy the link or try again."
        case .focusFailed: "The Focus Shortcut failed. Focus was left unchanged; the meeting still opened."
        case .focusNotConfigured: "The Focus Shortcut is not set up."
        case .speechModelMissing: "The speech model is not installed. Install it to transcribe; no audio is captured meanwhile."
        case .summaryModelMissing: "The summary model is not installed. The transcript is saved; you can summarize later."
        case .modelVerifyFailed: "A downloaded model file failed verification and was not installed."
        case .sourceFailed: "An audio source failed. Recording stopped or continues with only the working source after you confirm."
        case .micDenied: "Microphone access is off."
        case .queueOverflow: "Transcription fell behind. Some audio was dropped and marked as a gap."
        case .inferenceCrashed: "The transcription service stopped. Saved text is kept and the interval is marked as a gap."
        case .databaseUnwritable: "Notes could not be saved. Your text is kept in the editor; export it to keep a copy."
        case .databaseTooNew: "This data was created by a newer version of the app. Update the app to open it."
        case .summaryInvalid: "The summary could not be generated in a valid format. The transcript and previous summary are kept."
        case .updateVerifyFailed: "The update could not be verified and was not installed."
        case .identityAmbiguous: "This event could match more than one notebook. Choose the notebook to link."
        case .sessionInterrupted: "Recording was interrupted. You can resume with a new session segment."
        }
    }
}

public struct AppError: Error, Sendable, Equatable {
    public var code: AppErrorCode
    public var detail: String?
    public init(_ code: AppErrorCode, detail: String? = nil) { self.code = code; self.detail = detail }
    public var message: String { code.message }
}

/// Small entitlement interface; v1 grants everything (§25).
public enum Feature: String, Sendable, CaseIterable {
    case agenda, notebooks, talktrack, reminders, autoJoin, focus, transcription, summaries, quarter
}

public protocol FeatureEntitlementProvider: Sendable {
    func isEnabled(_ feature: Feature) -> Bool
}

public struct AllFeaturesEntitlementProvider: FeatureEntitlementProvider {
    public init() {}
    public func isEnabled(_ feature: Feature) -> Bool { true }
}

/// Redacts anything that might carry meeting content before it reaches logs/exports (§22.3).
public enum Redactor {
    public static func redactURLs(_ s: String) -> String {
        s.replacingOccurrences(of: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+"#, with: "<url>", options: .regularExpression)
    }
    public static func redactPaths(_ s: String) -> String {
        s.replacingOccurrences(of: #"/Users/[^\s/]+"#, with: "/Users/<user>", options: .regularExpression)
    }
    public static func scrub(_ s: String) -> String { redactPaths(redactURLs(s)) }
}
