import Foundation

/// One canonical automation setting backing the two UI toggles (§10.3).
public enum AutomationMode: String, Sendable, Codable, CaseIterable {
    case off, transcript, transcriptAndSummary

    public var autoTranscribe: Bool { self != .off }
    public var autoSummary: Bool { self == .transcriptAndSummary }

    /// Turning summary on enables transcription; turning transcription off disables summary.
    public func settingTranscribe(_ on: Bool) -> AutomationMode {
        on ? (self == .off ? .transcript : self) : .off
    }
    public func settingSummary(_ on: Bool) -> AutomationMode {
        on ? .transcriptAndSummary : (self == .off ? .off : .transcript)
    }

    public var label: String {
        switch self {
        case .off: "Off"
        case .transcript: "Transcript"
        case .transcriptAndSummary: "Transcript + summary"
        }
    }
}

public enum LinkActionState: String, Sendable, Equatable {
    case idle, resolving, opening, openRequested, failed

    public func canTransition(to next: LinkActionState) -> Bool {
        switch (self, next) {
        case (.idle, .resolving), (.resolving, .opening), (.resolving, .failed),
             (.opening, .openRequested), (.opening, .failed),
             (.openRequested, .idle), (.failed, .idle), (.failed, .resolving), (.openRequested, .resolving):
            true
        default: false
        }
    }
}

public enum CaptureState: String, Sendable, Codable, Equatable, CaseIterable {
    case idle, preflight, starting, capturing, stopping, stopped, failed, interrupted

    public var isActive: Bool { [.preflight, .starting, .capturing, .stopping].contains(self) }

    public func canTransition(to next: CaptureState) -> Bool {
        switch (self, next) {
        case (.idle, .preflight), (.preflight, .starting), (.preflight, .failed), (.preflight, .stopped),
             (.starting, .capturing), (.starting, .failed), (.starting, .stopping),
             (.capturing, .stopping), (.capturing, .interrupted),
             (.stopping, .stopped), (.stopping, .interrupted),
             (.interrupted, .stopped):
            true
        default: false
        }
    }
}

public enum TranscriptionState: String, Sendable, Equatable {
    case unavailable, ready, processingChunks, draining, complete, partial, failed
}

public enum SummaryState: String, Sendable, Codable, Equatable {
    case notRequested, queued, loadingModel, generating, complete, failed, cancelled
}

public enum StopReason: String, Sendable, Codable {
    case user, scheduledEnd, calendarShortened, sleep, sessionResigned, sourceLost, permissionRevoked,
         memoryPressure, inferenceFailed, appQuit, crashRecovered, replaced, databaseError
}

/// Calendar-derived and user-chosen deadlines are tracked separately (§10.4).
public struct SessionDeadline: Sendable, Equatable {
    public var calendarDeadline: Date
    public var userExtendedDeadline: Date?

    public init(calendarDeadline: Date, userExtendedDeadline: Date? = nil) {
        self.calendarDeadline = calendarDeadline; self.userExtendedDeadline = userExtendedDeadline
    }

    /// A user extension is never silently shortened by a stale calendar refresh.
    public var effective: Date { max(calendarDeadline, userExtendedDeadline ?? .distantPast) }

    public static let endPromptLead: TimeInterval = 60
    public static let defaultExtension: TimeInterval = 15 * 60

    public var promptAt: Date { effective.addingTimeInterval(-Self.endPromptLead) }

    public mutating func extend(by seconds: TimeInterval, now: Date) {
        userExtendedDeadline = max(effective, now).addingTimeInterval(seconds)
    }

    public enum CalendarUpdateOutcome: Equatable { case unchanged, updated, stopNow }

    /// Apply a fresh calendar end time for the same occurrence identity.
    public mutating func applyCalendarEnd(_ newEnd: Date, now: Date) -> CalendarUpdateOutcome {
        guard newEnd != calendarDeadline else { return .unchanged }
        calendarDeadline = newEnd
        if effective <= now { return .stopNow }
        return .updated
    }
}

public enum PreflightFailure: String, Sendable, Error, Equatable {
    case speechModelMissing, microphoneDenied, systemAudioUnavailable, microphoneUnavailable,
         sourcesNotTested, deadlinePassed, anotherCaptureActive, notOptedIn
}

public struct PreflightInput: Sendable {
    public var optedIn: Bool
    public var speechModelReady: Bool
    public var microphoneAuthorized: Bool
    public var sourcesTested: Bool
    public var deadline: Date
    public var now: Date
    public var activeCapture: UUID?
    public var occurrenceID: UUID
    public var isManual: Bool

    public init(optedIn: Bool, speechModelReady: Bool, microphoneAuthorized: Bool, sourcesTested: Bool, deadline: Date,
                now: Date, activeCapture: UUID?, occurrenceID: UUID, isManual: Bool) {
        self.optedIn = optedIn; self.speechModelReady = speechModelReady; self.microphoneAuthorized = microphoneAuthorized
        self.sourcesTested = sourcesTested; self.deadline = deadline; self.now = now; self.activeCapture = activeCapture
        self.occurrenceID = occurrenceID; self.isManual = isManual
    }
}

public enum SessionPreflight {
    /// Automatic capture requires opt-in, ready model, permissions, tested sources, and a future deadline (§10.2, §13.3).
    public static func check(_ i: PreflightInput) -> PreflightFailure? {
        if !i.isManual && !i.optedIn { return .notOptedIn }
        if let a = i.activeCapture, a != i.occurrenceID { return .anotherCaptureActive }
        if !i.speechModelReady { return .speechModelMissing }
        if !i.microphoneAuthorized { return .microphoneDenied }
        if !i.isManual && !i.sourcesTested { return .sourcesNotTested }
        if i.deadline <= i.now { return .deadlinePassed }
        return nil
    }
}

public enum CaptureSource: String, Sendable, Codable, CaseIterable {
    case microphone, system

    public var label: String { self == .microphone ? "You" : "Other participants" }
}

public enum CaptureSourceSelection: String, Sendable, Codable {
    case both, microphoneOnly, systemOnly
    public var sources: [CaptureSource] {
        switch self {
        case .both: [.microphone, .system]
        case .microphoneOnly: [.microphone]
        case .systemOnly: [.system]
        }
    }
}
