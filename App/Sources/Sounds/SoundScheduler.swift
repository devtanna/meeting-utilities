import AppKit
import Combine
import Foundation
import MeetingCore

/// Plays the before-meeting sound and the interval chime. One timer for the next cue; re-planned on calendar and
/// settings changes, wake, and clock/time-zone changes. Cues missed while asleep are skipped.
///
/// Sounds never play while nobody is at the Mac: system asleep (including Power Nap dark wakes), displays asleep,
/// screen locked, or another user's session in front. Cues that come due then are consumed silently.
@MainActor
final class SoundScheduler {
    private let calendar: CalendarEngine
    private let settings: AppSettings
    private var timer: Timer?
    private var played = Set<String>()
    private var lastInterval: Date?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var systemAsleep = false
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false

    init(calendar: CalendarEngine, settings: AppSettings) {
        self.calendar = calendar
        self.settings = settings
    }

    func start() {
        settings.objectWillChange.debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.replan() }.store(in: &cancellables)
        calendar.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.replan() }.store(in: &cancellables)
        let ws = NSWorkspace.shared.notificationCenter
        let presence: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.willSleepNotification), (ws, NSWorkspace.didWakeNotification),
            (ws, NSWorkspace.screensDidSleepNotification), (ws, NSWorkspace.screensDidWakeNotification),
            (ws, NSWorkspace.sessionDidResignActiveNotification), (ws, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default(), .screenIsLocked), (DistributedNotificationCenter.default(), .screenIsUnlocked),
        ]
        for (center, name) in presence {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presenceChanged(name) }
            })
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.replan() }
            })
        }
        replan()
    }

    private func presenceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        case .screenIsLocked: screenLocked = true
        case .screenIsUnlocked: screenLocked = false
        default: break
        }
        replan()
    }

    /// Nobody is at the Mac. The display check also catches dark wakes, where no screensDidWake is posted.
    private var isAway: Bool {
        systemAsleep || screensAsleep || screenLocked || sessionInactive || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private var meetingItems: [AgendaItem] {
        AgendaBuilder.applyFilters(calendar.plannerItems, filters: settings.filters)
    }

    func replan() {
        timer?.invalidate()
        let now = Date()
        var next: Date?
        if settings.meetingSoundEnabled,
           let cue = ChimePlanner.meetingCues(meetingItems, leadMinutes: settings.meetingSoundLead, now: now, alreadyPlayed: played).first {
            next = cue.fireAt
        }
        if settings.intervalSoundEnabled,
           var i = ChimePlanner.nextInterval(after: now, everyMinutes: settings.intervalMinutes, window: settings.intervalWindow) {
            if i == lastInterval,
               let later = ChimePlanner.nextInterval(after: i.addingTimeInterval(1), everyMinutes: settings.intervalMinutes, window: settings.intervalWindow) {
                i = later
            }
            next = min(next ?? i, i)
        }
        guard let next else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer?.tolerance = 0.3
    }

    private func fire() {
        let now = Date()
        let away = isAway
        // `playedSomething` doubles as "a sound slot is taken", so nothing plays while away.
        var playedSomething = away
        if settings.meetingSoundEnabled {
            let due = ChimePlanner.meetingCues(meetingItems, leadMinutes: settings.meetingSoundLead, now: now, alreadyPlayed: played)
                .filter { $0.fireAt <= now.addingTimeInterval(0.5) }
            for cue in due { played.insert(cue.key) }
            if !due.isEmpty, !away {
                SoundPlayer.shared.play(settings.meetingSound, volume: settings.soundVolume)
                playedSomething = true
            }
        }
        if settings.intervalSoundEnabled {
            // Fire if we're within a second of a boundary (the timer may land just before or after it).
            let prev = ChimePlanner.nextInterval(after: now.addingTimeInterval(-1.5), everyMinutes: settings.intervalMinutes)
            if abs(prev.timeIntervalSince(now)) < 1.5, lastInterval != prev, settings.intervalWindow.contains(prev) {
                lastInterval = prev
                // One sound at a time: a meeting sound at the same moment wins.
                if !playedSomething { SoundPlayer.shared.play(settings.intervalSound, volume: settings.soundVolume) }
            }
        }
        if played.count > 500 { played.removeAll() }
        replan()
    }
}

private extension Notification.Name {
    static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}
