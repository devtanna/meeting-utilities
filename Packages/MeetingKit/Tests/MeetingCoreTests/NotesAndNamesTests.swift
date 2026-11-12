import Foundation
import Testing
@testable import MeetingCore

@Suite("Topic summaries v2")
struct TopicSummaryTests {
    @Test func decodesTopicsAndBareStringPoints() {
        let json = #"{"schemaVersion":2,"overview":"Renewal call.","topics":[{"title":"Pricing for the Acme renewal","points":[{"text":"Acme wants 10% off.","sourceSegmentIDs":["S3"]},"Discount needs CFO sign-off."]}],"actionItems":[{"text":"Send the revised quote","owner":"Priya","dueDateText":"Friday","sourceSegmentIDs":["S4"]}]}"#
        let s = SummaryPrompt.decode(json)!
        #expect(s.topics.count == 1 && s.topics[0].points.count == 2)
        #expect(s.topics[0].points[1].text == "Discount needs CFO sign-off." && s.topics[0].points[1].sourceSegmentIDs.isEmpty)
        #expect(SummaryV1.nextStepLine(s.actionItems[0]) == "**Priya:** Send the revised quote, by Friday")
        #expect(s.markdown().contains("## Pricing for the Acme renewal") && s.markdown().contains("## Next steps"))
    }

    @Test func oldVersionOneSummariesStillDecode() {
        let s = SummaryPrompt.decode(#"{"schemaVersion":1,"overview":"o","discussionPoints":["Hiring"]}"#)!
        #expect(s.discussionPoints == ["Hiring"] && s.topics.isEmpty)
        #expect(SummaryValidator.validate(s, knownSegmentIDs: [], gapNotes: []).0.schemaVersion == 1)
    }

    @Test func partialStreamShowsWhatIsWrittenSoFar() {
        let stream = #"{"schemaVersion":2,"overview":"Weekly sync.","topics":[{"title":"Desktop app launch","points":[{"text":"Beta ships Tues"#
        let p = SummaryPrompt.decodePartial(stream)
        #expect(p?.overview == "Weekly sync.")
        #expect(p?.topics.first?.title == "Desktop app launch")
        #expect(p?.topics.first?.points.first?.text == "Beta ships Tues")
        // A key with no value yet is dropped rather than failing the whole draft.
        #expect(SummaryPrompt.decodePartial(#"{"overview":"Weekly sync.","topics":"#)?.overview == "Weekly sync.")
        #expect(SummaryPrompt.decodePartial("{") == nil)
    }

    @Test func validatorKeepsNotePointsAndDropsUnknownCitations() {
        var s = SummaryV1()
        s.topics = [.init(title: "Hiring", points: [.init(text: "Two roles open.", sourceSegmentIDs: ["S1", "S99"]), .init(text: "From notes.", sourceSegmentIDs: []), .init(text: "…")]),
                    .init(title: "Empty", points: [])]
        let (v, r) = SummaryValidator.validate(s, knownSegmentIDs: ["S1"], gapNotes: [])
        #expect(v.topics.count == 1 && v.topics[0].points.map(\.text) == ["Two roles open.", "From notes."])
        #expect(v.topics[0].points[0].sourceSegmentIDs == ["S1"] && r.removedCitations == 1)
        #expect(v.schemaVersion == 2)
    }

    @Test func mergeJoinsTheSameTopicAcrossParts() {
        var a = SummaryV1(); a.topics = [.init(title: "Pricing", points: [.init(text: "Acme wants 10% off.", sourceSegmentIDs: ["S3"])])]
        var b = SummaryV1(); b.topics = [.init(title: "pricing", points: [.init(text: "Acme wants 10% off", sourceSegmentIDs: ["S30"]), .init(text: "CFO must approve.", sourceSegmentIDs: ["S31"])]),
                                         .init(title: "Launch", points: [.init(text: "Beta on Tuesday.", sourceSegmentIDs: ["S40"])])]
        let m = SummaryMerge.merge([a, b], overview: "o", discussionPoints: nil)
        #expect(m.topics.map(\.title) == ["Pricing", "Launch"])
        #expect(m.topics[0].points.map(\.text) == ["Acme wants 10% off.", "CFO must approve."])
    }

    @Test func promptCarriesTitlePeopleLengthAndNotes() {
        let c = SummaryContext(title: "Acme renewal", attendees: ["Priya Shah"], userName: "Dev", minutes: 32, notes: "GOAL: get CFO sign-off\n- ask about seats")
        let p = SummaryPrompt.sectionPrompt(context: c, segments: [SummarySegment(id: "S1", source: "Them", offsetMs: 0, endOffsetMs: 1, text: "Hi")], sectionIndex: 0, sectionCount: 1)
        #expect(p.contains("Meeting: Acme renewal"))
        #expect(p.contains("People invited: Priya Shah.") && p.contains("\"Them\" is Priya Shah."))
        #expect(p.contains("Length: about 32 minutes."))
        #expect(p.contains("<notes>\nGOAL: get CFO sign-off"))
        #expect(p.contains("[S1|Them|00:00:00] Hi"))
        // Long notes are cut so they never crowd out the transcript.
        let long = SummaryContext(notes: String(repeating: "x", count: 20_000))
        #expect(SummaryPrompt.transcriptBudget(long) >= 1500)
        #expect(SummaryPrompt.sectionPrompt(context: long, segments: [], sectionIndex: 0, sectionCount: 1).count < 4_000 + 6_000)
    }
}

@Suite("Names from calls")
struct CallNamesTests {
    @Test func zoomTiles() {
        let t = CallReader.zoomTile("Ana Ruiz, Computer audio unmuted, Video off, Active speaker")
        #expect(t?.name == "Ana Ruiz" && t?.talking == true)
        #expect(CallReader.zoomTile("Ben Ode (Host), Computer audio muted")?.talking == false)
        #expect(CallReader.zoomTile("Ben Ode (Host), Computer audio muted")?.name == "Ben Ode")
        #expect(CallReader.zoomTile("Share Screen, Button") == nil)
    }

    @Test func zoomWindowReading() {
        let tree = AXNode(role: "AXWindow", children: [
            AXNode(role: "AXTabGroup", label: "Ana Ruiz, Computer audio unmuted, Active speaker"),
            AXNode(role: "AXTabGroup", label: "Dev Tanna (me), Computer audio unmuted"),
            AXNode(role: "AXTabGroup", label: "Ben Ode, Computer audio muted"),
        ])
        let r = CallReader.read(.zoom, [AXWindowSnapshot(title: "Zoom Meeting", identifier: nil, tree: tree)])
        #expect(r.speaking == ["Ana Ruiz"])
        #expect(r.participants == ["Ana Ruiz", "Dev Tanna", "Ben Ode"])
    }

    @Test func meetTilesAndTalkingClass() {
        func tile(_ name: String, talking: Bool) -> AXNode {
            var n = AXNode(role: "AXStaticText", value: name)
            for i in 0..<7 { n = AXNode(role: "AXGroup", classes: i == 3 && talking ? ["v5h6Xc"] : [], children: [n]) }
            return n
        }
        let tree = AXNode(role: "AXWindow", children: [AXNode(role: "AXGroup", children: [tile("Ana Ruiz", talking: true), tile("You", talking: false), tile("10:42", talking: false)])])
        let r = CallReader.read(.meet, [AXWindowSnapshot(title: "Meet - abc-defg-hij", identifier: nil, tree: tree)])
        #expect(r.participants == ["Ana Ruiz", "You"])
        #expect(r.speaking == ["Ana Ruiz"] && r.me == "You")
    }

    @Test func teamsLabels() {
        let tree = AXNode(role: "AXWindow", children: [AXNode(role: "AXButton", label: "Ana Ruiz, speaking"), AXNode(role: "AXGroup", label: "Ben Ode, muted"), AXNode(role: "AXRow", title: "Dev Tanna (You)")])
        let r = CallReader.read(.teams, [AXWindowSnapshot(title: "Meeting", identifier: nil, tree: tree)])
        #expect(r.speaking == ["Ana Ruiz"] && r.me == "Dev Tanna")
        #expect(Set(r.participants) == ["Ben Ode", "Dev Tanna"])
    }

    @Test func attributionNeedsMostOfTheLine() {
        let ana = CallReading(speaking: ["Ana"], participants: ["Ana", "Ben", "Dev"], me: "Dev")
        let ben = CallReading(speaking: ["Ben"], participants: ["Ana", "Ben", "Dev"], me: "Dev")
        let samples = [CallSample(t: 0, reading: ana), CallSample(t: 0.4, reading: ana), CallSample(t: 0.8, reading: ana), CallSample(t: 1.2, reading: ben), CallSample(t: 1.6, reading: ben)]
        #expect(CallAttribution.name(start: 0, end: 1.4, samples: samples) == "Ana")
        // Half and half is not "most": no name.
        #expect(CallAttribution.name(start: 0.6, end: 1.8, samples: samples) == nil)
        // A reading never stands longer than the hold: long after the last one nobody is named.
        #expect(CallAttribution.name(start: 10, end: 12, samples: samples) == nil)
    }

    @Test func oneOtherPersonIsAlwaysThem() {
        let r = CallReading(speaking: [], participants: ["Ana Ruiz", "Dev Tanna"], me: nil)
        let samples = [CallSample(t: 0, reading: r), CallSample(t: 1, reading: r)]
        #expect(CallAttribution.name(start: 0, end: 1.5, samples: samples, myNames: ["Dev Tanna"]) == "Ana Ruiz")
        // Without knowing which one is "me", two people can't be told apart.
        #expect(CallAttribution.name(start: 0, end: 1.5, samples: samples) == nil)
        // The person using this Mac is never a name for the other side.
        let me = CallReading(speaking: ["Dev Tanna"], participants: ["Ana", "Ben", "Dev Tanna"], me: nil)
        #expect(CallAttribution.name(start: 0, end: 1, samples: [CallSample(t: 0, reading: me)], myNames: ["Dev Tanna"]) == nil)
    }
}
