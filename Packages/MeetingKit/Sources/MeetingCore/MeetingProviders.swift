import Foundation

// Provider detection approach is informed by MeetingBar's MeetingLinkDetector (Apache-2.0, commit 93a0071);
// no code was copied. See THIRD_PARTY_NOTICES.md.

public enum MeetingProvider: String, Sendable, Codable, CaseIterable, Hashable {
    case googleMeet, zoom, teams

    public var displayName: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        }
    }

    public var joinLabel: String {
        switch self {
        case .googleMeet: "Join Meet Event"
        case .zoom: "Join Zoom Event"
        case .teams: "Join Teams Event"
        }
    }

    /// Bundle identifiers of native apps that can open the provider's HTTPS links.
    public var nativeAppBundleIDs: [String] {
        switch self {
        case .googleMeet: []
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        }
    }
}

public enum LinkField: Int, Sendable, Codable, Comparable, Hashable {
    case url = 0, location = 1, notes = 2
    public static func < (a: LinkField, b: LinkField) -> Bool { a.rawValue < b.rawValue }
}

public struct MeetingLinkCandidate: Sendable, Hashable, Codable, Identifiable {
    public var id: String { url.absoluteString }
    public var provider: MeetingProvider
    public var url: URL
    public var field: LinkField
    public var position: Int
    public init(provider: MeetingProvider, url: URL, field: LinkField, position: Int) {
        self.provider = provider; self.url = url; self.field = field; self.position = position
    }
}

public protocol MeetingLinkResolver: Sendable {
    func candidates(for event: CalendarOccurrenceSnapshot) -> [MeetingLinkCandidate]
}

/// Data-driven provider rule: host suffixes plus a path predicate. Rules are testable data (§8.1).
public struct ProviderRule: Sendable {
    public var provider: MeetingProvider
    public var hosts: [String]          // exact host or dot-suffix (".zoom.us")
    public var schemes: Set<String>
    public var pathPatterns: [String]   // anchored regex on the URL path

    func matchesHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return hosts.contains { rule in
            if rule.hasPrefix(".") { return h.hasSuffix(rule) && h.count > rule.count }
            return h == rule
        }
    }
}

public struct ProviderCatalog: Sendable {
    public var rules: [ProviderRule]

    public static let standard = ProviderCatalog(rules: [
        ProviderRule(
            provider: .googleMeet, hosts: ["meet.google.com"], schemes: ["https"],
            pathPatterns: [#"^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$"#, #"^/lookup/[A-Za-z0-9_-]+/?$"#]),
        ProviderRule(
            provider: .zoom,
            hosts: ["zoom.us", ".zoom.us", "zoom.com", ".zoom.com", "zoomgov.com", ".zoomgov.com", "zoom.com.cn", ".zoom.com.cn"],
            schemes: ["https"],
            pathPatterns: [#"^/j/\d{9,12}/?$"#, #"^/w/\d{9,12}/?$"#, #"^/s/\d{9,12}/?$"#, #"^/my/[A-Za-z0-9._-]+/?$"#,
                           #"^/wc/join/\d{9,12}/?$"#, #"^/wc/\d{9,12}/join/?$"#]),
        ProviderRule(
            provider: .teams,
            hosts: ["teams.microsoft.com", "teams.live.com", "gov.teams.microsoft.us", "dod.teams.microsoft.us", "teams.cloud.microsoft"],
            schemes: ["https"],
            pathPatterns: [#"^/l/meetup-join/.+"#, #"^/meet/\d+/?$"#, #"^/meet/[A-Za-z0-9]+/?$"#, #"^/v2/\?meetingjoin=true"#,
                           #"^/l/meet/.+"#]),
    ])

    public func provider(for url: URL) -> MeetingProvider? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased() else { return nil }
        if scheme == "zoommtg" || scheme == "zoomus" {
            return comps.host?.lowercased().hasSuffix("zoom.us") == true ? .zoom : nil
        }
        if scheme == "msteams" { return .teams }
        guard let host = comps.host, comps.user == nil, comps.password == nil else { return nil }
        for rule in rules where rule.schemes.contains(scheme) && rule.matchesHost(host) {
            let path = comps.percentEncodedPath
            for pattern in rule.pathPatterns where path.range(of: pattern, options: .regularExpression) != nil {
                return rule.provider
            }
        }
        return nil
    }
}

/// Extracts, unwraps, validates, ranks, and deduplicates conferencing links (§8.2).
public final class LinkExtractor: MeetingLinkResolver, @unchecked Sendable {
    public static let maxInputLength = 64 * 1024
    public static let maxUnwrapPasses = 3

    private let catalog: ProviderCatalog
    private let candidateRegex: NSRegularExpression
    private let lock = NSLock()
    private var cache: [Int: [MeetingLinkCandidate]] = [:]
    private var cacheOrder: [Int] = []

    public init(catalog: ProviderCatalog = .standard) {
        self.catalog = catalog
        candidateRegex = try! NSRegularExpression(
            pattern: #"(?:https?|zoommtg|zoomus|msteams)://[^\s<>"'\)\]\}]+"#, options: [.caseInsensitive])
    }

    public func candidates(for event: CalendarOccurrenceSnapshot) -> [MeetingLinkCandidate] {
        var hasher = Hasher()
        hasher.combine(event.url); hasher.combine(event.location); hasher.combine(event.notes)
        let key = hasher.finalize()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let result = compute(url: event.url, location: event.location, notes: event.notes)
        lock.lock()
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > 512 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        lock.unlock()
        return result
    }

    public func compute(url: String?, location: String?, notes: String?) -> [MeetingLinkCandidate] {
        var found: [MeetingLinkCandidate] = []
        var seen = Set<String>()
        for (field, text) in [(LinkField.url, url), (.location, location), (.notes, notes)] {
            guard let text, !text.isEmpty else { continue }
            for (pos, raw) in rawCandidates(in: text).enumerated() {
                guard let resolved = unwrap(raw), let provider = catalog.provider(for: resolved) else { continue }
                let key = dedupeKey(resolved)
                if seen.insert(key).inserted {
                    found.append(MeetingLinkCandidate(provider: provider, url: resolved, field: field, position: pos))
                }
            }
        }
        return found.sorted { ($0.field, $0.position) < ($1.field, $1.position) }
    }

    func rawCandidates(in text: String) -> [String] {
        var input = String(text.prefix(Self.maxInputLength))
        // Calendar notes are frequently HTML; decode the entities that commonly wrap URLs.
        for (entity, value) in [("&amp;", "&"), ("&#38;", "&"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#x3D;", "=")] {
            input = input.replacingOccurrences(of: entity, with: value)
        }
        let ns = input as NSString
        return candidateRegex.matches(in: input, range: NSRange(location: 0, length: ns.length)).map {
            var s = ns.substring(with: $0.range)
            while let last = s.last, ".,;:!?*".contains(last) { s.removeLast() }
            return s
        }
    }

    /// Unwrap Outlook Safe Links and Google redirects locally. Never fetches anything (§8.2).
    public func unwrap(_ raw: String) -> URL? {
        var current = raw
        for _ in 0...Self.maxUnwrapPasses {
            guard current.count <= 8192, let comps = URLComponents(string: current), let host = comps.host?.lowercased() else { return nil }
            let items = comps.queryItems ?? []
            if host.hasSuffix(".safelinks.protection.outlook.com"),
               let inner = items.first(where: { $0.name == "url" })?.value {
                current = inner; continue
            }
            if (host == "www.google.com" || host == "google.com") && comps.path == "/url",
               let inner = items.first(where: { $0.name == "q" || $0.name == "url" })?.value {
                current = inner; continue
            }
            return comps.url
        }
        return nil // exceeded pass budget
    }

    func dedupeKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.host = c.host?.lowercased()
        c.scheme = c.scheme?.lowercased()
        var path = c.percentEncodedPath
        if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        c.percentEncodedPath = path
        return c.string ?? url.absoluteString
    }
}

public enum LinkOverrideScope: String, Sendable, Codable { case occurrence, series }

public struct LinkOverride: Sendable, Codable, Equatable {
    public var url: String
    public var scope: LinkOverrideScope
    public init(url: String, scope: LinkOverrideScope) { self.url = url; self.scope = scope }
}

public enum LinkSelection {
    /// Applies a user override if the candidate still exists; flags it for review when it disappeared (§8.2).
    public static func choose(candidates: [MeetingLinkCandidate], override: LinkOverride?) -> (MeetingLinkCandidate?, overrideMissing: Bool) {
        if let override {
            if let match = candidates.first(where: { $0.url.absoluteString == override.url }) { return (match, false) }
            return (candidates.first, true)
        }
        return (candidates.first, false)
    }
}

public enum OpenPreference: String, Sendable, Codable, CaseIterable {
    case defaultBrowser, nativeApp
}
