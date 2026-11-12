import AppKit
import ApplicationServices
import Foundation
import MeetingAudio
import MeetingCore

/// While a meeting is transcribed, reads the call app (Zoom, Teams, or Google Meet in a browser) through macOS
/// Accessibility about twice a second, read-only: who is in the call and who it marks as talking. Lines from the other
/// side are then named after that person (`CallAttribution`). Without the Accessibility permission, in another app, or
/// when the app shows nothing clear, lines stay unnamed. Nothing leaves the Mac and nothing is clicked or changed.
/// The tree-reading approach is adapted from Yogurt's yogurt-mac call-watch (MIT); see THIRD_PARTY_NOTICES.md.
final class CallWatcher: @unchecked Sendable {
    static let interval = 0.4
    /// Readings older than this are no use: a line is named within a minute or two of being said.
    static let keepSeconds = 15.0 * 60

    private let queue = DispatchQueue(label: "call.watch", qos: .utility)
    private let lock = NSLock()
    private var samples: [CallSample] = []
    private var everyone: [String] = []
    private var running = false
    private var askedTree = Set<pid_t>()
    private var loggedTree = false
    private var myNames: [String] = []

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the person to Privacy & Security › Accessibility.
    @discardableResult
    static func requestTrust() -> Bool {
        // The value of kAXTrustedCheckOptionPrompt, spelled out (the global is not concurrency-safe to read).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    func start(myNames: [String]) {
        lock.withLock {
            samples = []; everyone = []; running = true; loggedTree = false
            self.myNames = myNames.filter { !$0.isEmpty }
        }
        queue.async { [weak self] in self?.loop() }
    }

    func stop() { lock.withLock { running = false } }

    /// The other side's speaker for a line spoken between these capture host times, or nil.
    func name(start: Double, end: Double) -> String? {
        let (s, mine) = lock.withLock { (samples, myNames) }
        return CallAttribution.name(start: start, end: end, samples: s, myNames: mine)
    }

    /// Everyone the call app showed during this meeting (the person using this Mac excluded).
    var participants: [String] { lock.withLock { everyone } }

    private func loop() {
        guard lock.withLock({ running }) else { return }
        let started = Date()
        if AXIsProcessTrusted(), let reading = readOnce() {
            let t = HostTime.now() - CallAttribution.appLag
            lock.withLock {
                samples.append(CallSample(t: t, reading: reading))
                if let first = samples.firstIndex(where: { $0.t >= t - Self.keepSeconds }), first > 0 { samples.removeFirst(first) }
                for p in reading.participants where p != reading.me && !myNames.contains(p) && !everyone.contains(p) { everyone.append(p) }
            }
        }
        // A slow app (a big page) is read less often, so reading never takes much of the Mac.
        let took = Date().timeIntervalSince(started)
        queue.asyncAfter(deadline: .now() + max(Self.interval, took * 2)) { [weak self] in self?.loop() }
    }

    /// The frontmost call app that shows a call, else the first running one that does.
    private func readOnce() -> CallReading? {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = CallApps.all.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .sorted { a, _ in a.processIdentifier == front }
        for app in apps {
            guard let id = app.bundleIdentifier, let kind = CallApps.kind(bundleID: id) else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            let windows = ((Self.attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter {
                CallApps.isCallWindow(bundleID: id, identifier: Self.text(Self.attr($0, kAXIdentifierAttribute)), title: Self.text(Self.attr($0, kAXTitleAttribute)))
            }
            guard !windows.isEmpty else { continue }
            if CallApps.chromium.contains(id), !askedTree.contains(app.processIdentifier) {
                // Chromium and Electron build a page's tree only when an assistive app asks, the way screen readers do.
                AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                askedTree.insert(app.processIdentifier)
            }
            let zoom = kind == .zoom
            var budget = zoom ? 1500 : 4000
            let snaps = windows.prefix(4).map { w in
                AXWindowSnapshot(title: Self.text(Self.attr(w, kAXTitleAttribute)), identifier: Self.text(Self.attr(w, kAXIdentifierAttribute)),
                                 tree: Self.copy(w, depth: 0, maxDepth: zoom ? 14 : 40, budget: &budget, zoom: zoom))
            }
            let reading = CallReader.read(kind, Array(snaps))
            if !lock.withLock({ loggedTree }) {
                lock.withLock { loggedTree = true }
                Log.capture.info("call names: \(kind.rawValue, privacy: .public) windows=\(snaps.count, privacy: .public) participants=\(reading.participants.count, privacy: .public) speaking=\(reading.speaking.count, privacy: .public) me=\(reading.me != nil, privacy: .public)")
            }
            return reading
        }
        return nil
    }

    private static let keyNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute,
                                   kAXIdentifierAttribute, "AXDOMClassList", kAXChildrenAttribute]

    /// One element and what is under it, depth and element count bounded (Zoom's toolbar lists itself as its own child).
    private static func copy(_ e: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int, zoom: Bool) -> AXNode {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(e, keyNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let vals = (raw as? [AnyObject]) ?? []
        func at(_ i: Int) -> AnyObject? {
            guard i < vals.count else { return nil }
            let v = vals[i]
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
        let role = text(at(0)) ?? ""
        var node = AXNode(role: role, subrole: text(at(1)), label: text(at(2)), title: text(at(3)),
                          // What someone types is never copied.
                          value: role == "AXTextField" || role == "AXTextArea" ? nil : text(at(4)),
                          identifier: text(at(5)), classes: ((at(6) as? [String]) ?? []).prefix(20).map { $0 })
        // A Zoom tile's description says it all; its children are buttons.
        if zoom && role == "AXTabGroup" { return node }
        guard depth < maxDepth, let kids = at(7) as? [AXUIElement], !kids.isEmpty else { return node }
        for k in kids {
            if budget <= 0 { break }
            node.children.append(copy(k, depth: depth + 1, maxDepth: maxDepth, budget: &budget, zoom: zoom))
        }
        return node
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func text(_ v: AnyObject?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s.count > 300 ? String(s.prefix(300)) : s
    }
}
