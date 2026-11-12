import Foundation

// Names from the call: who is in a Zoom, Teams or Google Meet call and who the app marks as talking, read from the
// app's accessibility tree, then used to name lines from the other side. Every rule fails towards reading nothing, so
// a changed app means an unnamed line ("Them"), never a wrong name. The per-app rules and the attribution are adapted
// from Yogurt (FrigadeHQ/yogurt, MIT, app/src/main/callNames); see THIRD_PARTY_NOTICES.md.

/// One element of a call window's accessibility tree, copied out read-only. Text fields' values are never copied.
public struct AXNode: Sendable {
    public var role: String
    public var subrole: String?
    public var label: String?        // AXDescription
    public var title: String?
    public var value: String?
    public var identifier: String?
    public var classes: [String]     // AXDOMClassList (browsers)
    public var children: [AXNode]

    public init(role: String, subrole: String? = nil, label: String? = nil, title: String? = nil, value: String? = nil,
                identifier: String? = nil, classes: [String] = [], children: [AXNode] = []) {
        self.role = role; self.subrole = subrole; self.label = label; self.title = title; self.value = value
        self.identifier = identifier; self.classes = classes; self.children = children
    }

    var texts: [String] { [label, title, value].compactMap { $0 } }

    /// Depth-first, with the chain of ancestors (outermost first).
    func walk(_ up: inout [AXNode], _ fn: (AXNode, [AXNode]) -> Void) {
        fn(self, up)
        up.append(self)
        for k in children { k.walk(&up, fn) }
        up.removeLast()
    }

    func walk(_ fn: (AXNode, [AXNode]) -> Void) {
        var up: [AXNode] = []
        walk(&up, fn)
    }
}

public struct AXWindowSnapshot: Sendable {
    public var title: String?
    public var identifier: String?
    public var tree: AXNode
    public init(title: String?, identifier: String?, tree: AXNode) { self.title = title; self.identifier = identifier; self.tree = tree }
}

public enum CallKind: String, Sendable { case zoom, teams, meet }

/// What the call app shows at one moment.
public struct CallReading: Sendable, Equatable {
    public var speaking: [String]
    public var participants: [String]
    /// The person using this Mac, when the app says which one they are ("(me)", "You").
    public var me: String?
    public init(speaking: [String] = [], participants: [String] = [], me: String? = nil) {
        self.speaking = speaking; self.participants = participants; self.me = me
    }
}

public enum CallApps {
    /// Bundle IDs read for each kind of call. Meet is a browser call.
    public static let zoom = ["us.zoom.xos"]
    public static let teams = ["com.microsoft.teams2", "com.microsoft.teams"]
    public static let browsers = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox"]
    public static var all: [String] { zoom + teams + browsers }
    /// Chromium and Electron build a page's tree only when an assistive app asks (AXManualAccessibility).
    public static let chromium: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.microsoft.teams", "com.microsoft.teams2"]

    public static func kind(bundleID: String) -> CallKind? {
        if zoom.contains(bundleID) { return .zoom }
        if teams.contains(bundleID) { return .teams }
        if browsers.contains(bundleID) { return .meet }
        return nil
    }

    /// Which of an app's windows hold the call, from their identifier and title.
    public static func isCallWindow(bundleID: String, identifier: String?, title: String?) -> Bool {
        let title = title ?? ""
        switch kind(bundleID: bundleID) {
        case .zoom: return (identifier ?? "").hasPrefix("zm.meeting") || title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar")
        case .teams: return true
        case .meet: return title.range(of: #"\bMeet\b"#, options: .regularExpression) != nil
        case nil: return false
        }
    }
}

public enum CallReader {
    public static func read(_ kind: CallKind, _ windows: [AXWindowSnapshot], meetTalkingClasses: Set<String> = meetTalkingClasses) -> CallReading {
        switch kind {
        case .zoom: readZoom(windows)
        case .meet: readMeet(windows, marks: meetTalkingClasses)
        case .teams: readTeams(windows)
        }
    }

    static func uniq(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0.lowercased()).inserted }
    }
    static func low(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespaces) }

    // MARK: Zoom (desktop app)
    // Each video tile is an AXTabGroup described "Name, Computer audio unmuted, Video off", with ", Active speaker" on
    // the person talking (Zoom marks someone only with three or more in the call). The participants panel, when open,
    // is an AXOutline "Participants list" with rows "Name (me)", "Name (Host)". The floating window says "Talking: Name".

    static let zoomWords: [[String]] = [
        ["Computer audio unmuted", "Computer audio muted", "Active speaker", "Talking:", "Participants list", "(me)"],
        ["Bei Computeraudio Stummschaltung deaktiviert", "Bei Computeraudio Stummschaltung aktiviert", "Aktiver Sprecher", "Sprechen:", "Teilnehmerliste", "(ich)"],
        ["Audio de la computadora no silenciado", "Audio de la computadora silenciado", "Orador activo", "Hablando:", "Lista de participantes", "(yo)"],
        ["Son de l'ordinateur rétabli", "Ordinateur mis en sourdine", "Intervenant actif", "La parole est à :", "Liste des participants", "(moi)"],
        ["Audio computer attivato", "Audio computer disattivato", "Oratore attivo", "Conversazione in corso:", "Elenco dei partecipanti", "(io)"],
        ["Áudio do computador ativado", "Áudio do computador desativado", "Orador ativo", "Falando:", "Lista de participantes", "(eu)"],
        ["Computeraudio ingeschakeld", "Computeraudio gedempt", "Actieve spreker", "Aan het spreken:", "Deelnemerslijst", "(ik)"],
        ["Datorljudet aktiverades", "Datorljudet inaktiverades", "Aktiv talare", "Talar:", "Deltagarlista", "(jag)"],
    ]
    static let zoomAudio = Set(zoomWords.flatMap { [low($0[0]), low($0[1])] })
    static let zoomActive = Set(zoomWords.map { low($0[2]) })
    static let zoomTalking = zoomWords.map { $0[3].replacingOccurrences(of: #"\s*[:：]$"#, with: "", options: .regularExpression) }
    static let zoomLists = Set(zoomWords.map { low($0[4]) })
    static let zoomSelf = zoomWords.map { $0[5] }
    static let zoomOtherStatus = try! NSRegularExpression(pattern: #"^(video (on|off)|no audio|telephone.*|screen sharing.*|pinned|spotlighted)$"#, options: .caseInsensitive)
    static let zoomTags = #"\s*[(（](me|host|co-host|guest|interpreter|participant id: [^)]*|ich|yo|moi|io|eu|ik|jag)[)）]\s*$"#

    static func cleanZoom(_ raw: String) -> String? {
        var name = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        while let r = name.range(of: zoomTags, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(r) }
        return name.isEmpty || name.lowercased().hasPrefix("participants (") ? nil : name
    }

    /// "Ana Ruiz, Computer audio unmuted, Video off, Active speaker" → Ana Ruiz, talking; nil when it isn't a tile.
    public static func zoomTile(_ description: String) -> (name: String, talking: Bool)? {
        var fields = description.precomposedStringWithCompatibilityMapping.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var talking = false, known = false
        while fields.count > 1 {
            let f = low(fields.last!)
            if zoomActive.contains(f) { talking = true; known = true }
            else if zoomAudio.contains(f) { known = true }
            else if zoomOtherStatus.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) == nil { break }
            fields.removeLast()
        }
        guard known, let name = cleanZoom(fields.joined(separator: ", ")) else { return nil }
        return (name, talking)
    }

    static func readZoom(_ windows: [AXWindowSnapshot]) -> CallReading {
        var speaking: [String] = [], participants: [String] = [], me: String?
        for w in windows {
            w.tree.walk { n, up in
                if n.role == "AXTabGroup", let d = n.label, let tile = zoomTile(d) {
                    participants.append(tile.name)
                    if tile.talking { speaking.append(tile.name) }
                }
                if n.role == "AXStaticText", let v = n.value?.precomposedStringWithCompatibilityMapping {
                    for key in zoomTalking where v.hasPrefix(key) {
                        let rest = String(v.dropFirst(key.count)).replacingOccurrences(of: #"^\s*[:：]\s*"#, with: "", options: .regularExpression)
                        if let name = cleanZoom(rest) { speaking.append(name) }
                    }
                }
                if n.role == "AXRow", up.contains(where: { $0.role == "AXOutline" && zoomLists.contains(low($0.label ?? $0.title ?? "")) }) {
                    var text: String?
                    n.walk { x, _ in if text == nil, x.role == "AXStaticText", let v = x.value { text = v } }
                    guard let text, let name = cleanZoom(text) else { return }
                    participants.append(name)
                    if zoomSelf.contains(where: { text.contains($0) }) { me = name }
                }
            }
        }
        return CallReading(speaking: uniq(speaking), participants: uniq(participants), me: me)
    }

    // MARK: Google Meet (in a browser)
    // Meet names nobody as talking in words. Each tile shows the person's name as text, and the talking tile gets a
    // CSS class that the browser's tree carries (AXDOMClassList). The class is a build name Google changes between
    // releases ("v5h6Xc" as of October 2026); when it is gone nobody is marked, and only a two-person call can be named.
    // A tile is the element seven levels above a name's text, holding just that one name.

    public static let meetTalkingClasses: Set<String> = ["v5h6Xc"]
    static let tileUp = 7
    static let notAName = try! NSRegularExpression(pattern: #"^\d{1,2}[:.]\d{2}(\s?[AP]M)?$|^[a-z]{3}-[a-z]{4}-[a-z]{3}$|says in chat|^(AM|PM)$|^\d+$"#, options: .caseInsensitive)

    static func meetName(_ text: String) -> String? {
        let name = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\s*\((presenting|presentation|you)[^)]*\)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        guard (2...60).contains(name.count), name.rangeOfCharacter(from: .letters) != nil,
              notAName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil else { return nil }
        return name
    }

    static func readMeet(_ windows: [AXWindowSnapshot], marks: Set<String>) -> CallReading {
        // Tiles are told apart by their position in the walk (value types have no identity).
        var groups: [Int: (root: AXNode, names: [String])] = [:]
        var order: [Int] = []
        for w in windows {
            if let t = w.title, t.range(of: #"\bMeet\b"#, options: .regularExpression) == nil { continue }
            let skip = Set((w.title ?? "").components(separatedBy: " - ").map(low))
            var index = 0
            var ids: [Int] = []          // walk-order id of each ancestor on the current path
            var up: [AXNode] = []
            func visit(_ n: AXNode) {
                let id = index; index += 1
                if n.role == "AXStaticText", let v = n.value, up.count >= tileUp, let name = meetName(v), !skip.contains(low(name)) {
                    let rootID = ids[ids.count - tileUp]
                    if groups[rootID] == nil { groups[rootID] = (up[up.count - tileUp], []); order.append(rootID) }
                    groups[rootID]!.names.append(name)
                }
                up.append(n); ids.append(id)
                for k in n.children { visit(k) }
                up.removeLast(); ids.removeLast()
            }
            visit(w.tree)
        }
        var speaking: [String] = [], participants: [String] = [], me: String?
        for id in order {
            guard let g = groups[id] else { continue }
            let one = uniq(g.names)
            guard one.count == 1 else { continue }
            participants.append(one[0])
            if low(one[0]) == "you" { me = one[0] }
            var talking = false
            g.root.walk { x, _ in if x.classes.contains(where: marks.contains) { talking = true } }
            if talking { speaking.append(one[0]) }
        }
        return CallReading(speaking: uniq(speaking), participants: uniq(participants), me: me)
    }

    // MARK: Microsoft Teams
    // Teams draws its talking ring as a style with no words, so only labels are read: "Name, speaking",
    // "Name is speaking", "Active speaker: Name", tiles "Name, muted" / "Name, video on", and "(You)" after the
    // person's own name. Lower confidence than Zoom; the first reading of each meeting is logged to check against.

    static let teamsSpeaking = [#"^(.{2,60}?)(?:,\s*|\s+is\s+)(?:speaking|talking)\b"#, #"\b(?:active speaker|now speaking|speaking now)[:,]?\s+(.{2,60})$"#]
    static let teamsTile = #"^(.{2,60}?),\s*(?:muted|unmuted|mic(?:rophone)? (?:on|off)|video (?:is )?(?:on|off)|camera (?:is )?(?:on|off))\b"#
    static let teamsMe = #"^(.{2,60}?)\s*\((?:you|me)\)"#

    static func firstGroup(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func cleanTeams(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\((?:organizer|presenter|guest|external|you|me)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[,.:;]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func readTeams(_ windows: [AXWindowSnapshot]) -> CallReading {
        var speaking: [String] = [], participants: [String] = [], me: String?
        for w in windows {
            w.tree.walk { n, _ in
                for label in n.texts {
                    for re in teamsSpeaking {
                        if let m = firstGroup(re, label) {
                            let name = cleanTeams(m)
                            if name.count >= 2, name.range(of: #"^(you|me)\b"#, options: [.regularExpression, .caseInsensitive]) == nil { speaking.append(name) }
                        }
                    }
                    if let t = firstGroup(teamsTile, label) { participants.append(cleanTeams(t)) }
                    if let m = firstGroup(teamsMe, label) { let name = cleanTeams(m); me = name; participants.append(name) }
                }
            }
        }
        return CallReading(speaking: uniq(speaking), participants: uniq(participants.filter { $0.count >= 2 }), me: me)
    }
}

/// One reading of the call app on the capture clock (host seconds), the app's own display lag already taken off.
public struct CallSample: Sendable, Equatable {
    public var t: Double
    public var reading: CallReading
    public init(t: Double, reading: CallReading) { self.t = t; self.reading = reading }
}

/// Who said a line from the other side, from what the call app showed while it was said. A name only when the app
/// marked that one person as talking for most of the line, or when the call has just one other person; else nil.
public enum CallAttribution {
    /// A reading stands until the next one, but never longer than this, so a stuck app never keeps naming someone.
    public static let hold = 2.0
    /// The apps mark the person talking about this late (Zoom: about 0.75–1.2 s after they start).
    public static let appLag = 0.75
    /// A name needs more than this share of the line.
    static let most = 0.5

    static func norm(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func isMe(_ name: String, _ r: CallReading, _ myNames: [String]) -> Bool {
        let n = norm(name)
        return (r.me.map(norm) == n) || myNames.contains { !$0.isEmpty && norm($0) == n }
    }

    /// Who the other side was at one reading, or nil when it can't be told.
    static func who(_ r: CallReading, _ myNames: [String]) -> String? {
        var seen = Set<String>()
        let people = r.participants.filter { seen.insert(norm($0)).inserted }
        // One other person in the call: the call's sound can only be them, whoever the app marks.
        if people.count == 2 {
            let mine = people.filter { isMe($0, r, myNames) }
            if mine.count == 1 { return people.first { !isMe($0, r, myNames) } }
        }
        var others: [String] = []
        for p in r.speaking where !isMe(p, r, myNames) && !others.contains(where: { norm($0) == norm(p) }) { others.append(p) }
        return others.count == 1 ? others[0] : nil
    }

    public static func name(start: Double, end: Double, samples: [CallSample], myNames: [String] = []) -> String? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.t < $1.t }
        func span(_ i: Int) -> (Double, Double) {
            (sorted[i].t, min(i + 1 < sorted.count ? sorted[i + 1].t : .infinity, sorted[i].t + hold))
        }
        if end <= start {
            for i in sorted.indices.reversed() {
                let (a, b) = span(i)
                if a <= start { return start < b ? who(sorted[i].reading, myNames) : nil }
            }
            return nil
        }
        var time: [String: (name: String, seconds: Double)] = [:]
        for i in sorted.indices {
            let (a, b) = span(i)
            let overlap = min(b, end) - max(a, start)
            guard overlap > 0, let w = who(sorted[i].reading, myNames) else { continue }
            time[norm(w), default: (w, 0)].seconds += overlap
        }
        guard let best = time.values.max(by: { $0.seconds < $1.seconds }), best.seconds > (end - start) * most else { return nil }
        return best.name
    }
}
