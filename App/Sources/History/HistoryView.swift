import MeetingCore
import MeetingData
import SwiftUI

/// Calendar window: month grid (EventKit events for the visible grid merged with saved occurrences, one bounded
/// query each, §5.4), day detail, and local full-text search (§9.3).
struct HistoryView: View {
    let services: AppServices
    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var saved: [OccurrenceSummary] = []
    @State private var events: [CalendarOccurrenceSnapshot] = []
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// `preloaded` fills the grid up front (snapshots render offscreen, where `.task` doesn't get to run).
    init(services: AppServices, preloaded: (saved: [OccurrenceSummary], events: [CalendarOccurrenceSnapshot])? = nil) {
        self.services = services
        if let preloaded {
            _saved = State(initialValue: preloaded.saved)
            _events = State(initialValue: preloaded.events)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            monthPanel
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            sidePanel
                .frame(width: 360)
                .padding(8)
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 920, minHeight: 600)
        .task(id: month) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: AppDatabase.didChange).debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            Task { await load() }
        }
    }

    var gridRange: DateInterval { FetchRanges.monthGrid(containing: month) }

    func load() async {
        let range = gridRange
        saved = (try? await services.store.occurrences(in: range)) ?? []
        events = (try? await services.calendar.repository.occurrences(in: range, calendarIDs: services.settings.selectedCalendarIDs)) ?? []
    }

    // MARK: Month panel

    var monthPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header shares the 52 pt title band with the traffic lights.
            HStack(spacing: 10) {
                Color.clear.frame(width: 64)
                HStack(spacing: 0) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 22) }.accessibilityLabel("Previous month")
                    Divider().frame(height: 14)
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 22) }.accessibilityLabel("Next month")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
                Button("Today") { month = Date(); selectedDay = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                Spacer()
                QuarterChip(info: services.quarter)
            }
            .frame(height: 52)
            .padding(.trailing, 8)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(month.formatted(.dateTime.month(.wide))).font(.system(size: 30, weight: .bold))
                Text(month.formatted(.dateTime.year())).font(.system(size: 30, weight: .regular)).foregroundStyle(.secondary)
                Spacer()
                legend
            }
            .padding(.horizontal, 6)

            grid
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    var legend: some View {
        HStack(spacing: 10) {
            Label("Notes", systemImage: "note.text")
            Label("Transcript", systemImage: "waveform")
            Label("Summary", systemImage: "text.alignleft")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    func shiftMonth(_ d: Int) { month = Calendar.current.date(byAdding: .month, value: d, to: month)! }

    var grid: some View {
        let cal = Calendar.current
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridRange.start)! }
        let symbols = cal.shortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(ordered.enumerated()), id: \.offset) {
                    Text($0.element.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(days, id: \.self) { day in
                    DayCell(day: day, inMonth: cal.isDate(day, equalTo: month, toGranularity: .month),
                            selected: selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false,
                            entries: entries(on: day))
                        .onTapGesture { selectedDay = day }
                }
            }
        }
    }

    // MARK: Merged day entries (calendar events + saved occurrences)

    struct DayEntry: Identifiable {
        var id: String
        var start: Date
        var end: Date
        var title: String
        var color: Color
        var saved: OccurrenceSummary?
        var event: CalendarOccurrenceSnapshot?
    }

    func entries(on day: Date) -> [DayEntry] {
        let cal = Calendar.current
        let s = saved.filter { cal.isDate($0.occurrence.start, inSameDayAs: day) }
        let e = events.filter { cal.isDate($0.start, inSameDayAs: day) && !$0.isCancelled }
        var out: [DayEntry] = []
        var usedEvents = Set<String>()
        for h in s {
            let match = e.first { $0.start == h.occurrence.start && $0.title == h.occurrence.titleSnapshot }
            if let match { usedEvents.insert(match.id) }
            out.append(DayEntry(id: h.occurrence.id.uuidString, start: h.occurrence.start, end: h.occurrence.end, title: h.occurrence.titleSnapshot,
                                color: match.map { Self.color($0.calendarColor) } ?? .gray, saved: h, event: match))
        }
        for ev in e where !usedEvents.contains(ev.id) {
            out.append(DayEntry(id: ev.id, start: ev.start, end: ev.end, title: ev.title, color: Self.color(ev.calendarColor), saved: nil, event: ev))
        }
        return out.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    static func color(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1) }

    // MARK: Side panel (search + day detail)

    var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.clear.frame(height: 30)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes, transcripts, summaries…", text: $query).textFieldStyle(.plain)
                    .onChange(of: query) { _, q in search(q) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !query.isEmpty { searchResults } else { dayDetail }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    @ViewBuilder var dayDetail: some View {
        if let day = selectedDay {
            let list = entries(on: day)
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.wide))).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.green)
                Text(day.formatted(.dateTime.day().month(.wide))).font(.system(size: 24, weight: .bold))
                Text(list.isEmpty ? "No meetings" : "\(list.count) meeting\(list.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Nothing scheduled").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                SettingsCard {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, entry in
                        if i > 0 { RowDivider() }
                        EntryRow(entry: entry) { open(entry) }
                    }
                }
            }
        }
    }

    func open(_ entry: DayEntry) {
        if let s = entry.saved { services.windows.openNotebook(occurrenceID: s.occurrence.id); return }
        guard let e = entry.event else { return }
        Task { if let r = try? await services.store.resolve(e) { services.windows.openNotebook(occurrenceID: r.occurrence.id, resolved: r) } }
    }

    @ViewBuilder var searchResults: some View {
        Text(hits.isEmpty ? "No results" : "\(hits.count) result\(hits.count == 1 ? "" : "s")")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 2)
        if !hits.isEmpty {
            SettingsCard {
                ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { RowDivider() }
                    Button { openHit(h) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(h.notebookTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(kindLabel(h.contentKind)).font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Brand.green.opacity(0.15), in: Capsule()).foregroundStyle(Brand.green)
                            }
                            if let d = h.occurrenceDate { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Text(highlighted(h.excerpt)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Search excerpts mark matches with «»; show them in bold instead.
    func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buf = ""
        func flush() { var a = AttributedString(buf); if bold { a.font = .system(size: 12, weight: .bold); a.foregroundColor = .primary }; out += a; buf = "" }
        for ch in s {
            if ch == "«" { flush(); bold = true } else if ch == "»" { flush(); bold = false } else { buf.append(ch) }
        }
        flush()
        return out
    }

    func openHit(_ h: SearchHit) {
        if let o = h.occurrenceID { services.windows.openNotebook(occurrenceID: o); return }
        // Series-level hits open the notebook at its most recent dated entry.
        Task {
            if let latest = try? await services.store.history(notebookID: h.notebookID, before: nil, limit: 1).first {
                services.windows.openNotebook(occurrenceID: latest.occurrence.id)
            }
        }
    }

    func kindLabel(_ k: String) -> String {
        switch k {
        case "notes": "Notes"
        case "notes-series": "Series notes"
        case "talktrack", "talktrack-series": "Talktrack"
        case "transcript": "Transcript"
        case "summary": "Summary"
        case "title": "Title"
        default: k
        }
    }

    func search(_ q: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            hits = (try? await services.store.search(q)) ?? []
        }
    }
}

/// One month-grid day: date badge, up to three event chips in calendar colour, and content badges.
private struct DayCell: View {
    var day: Date
    var inMonth: Bool
    var selected: Bool
    var entries: [HistoryView.DayEntry]
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let hasNotes = entries.contains { $0.saved?.hasNotes == true }
        let hasTranscript = entries.contains { ($0.saved?.transcriptSegments ?? 0) > 0 }
        let hasSummary = entries.contains { ($0.saved?.summaryCount ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                    .frame(width: 22, height: 22)
                    .background(isToday ? Brand.green : .clear, in: Circle())
                Spacer()
                HStack(spacing: 2) {
                    if hasNotes { Image(systemName: "note.text") }
                    if hasTranscript { Image(systemName: "waveform") }
                    if hasSummary { Image(systemName: "text.alignleft") }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Brand.green)
            }
            // Fits the fixed cell height: three chips, or two chips plus a "+N more" line.
            let visible = entries.count <= 3 ? 3 : 2
            ForEach(entries.prefix(visible)) { e in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(e.color).frame(width: 3, height: 10)
                    Text(e.title).font(.system(size: 10)).lineLimit(1).foregroundStyle(inMonth ? .primary : .secondary)
                }
            }
            if entries.count > 3 {
                Text("+\(entries.count - visible) more").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 86, alignment: .topLeading)
        .clipped()
        .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Brand.green : Color.primary.opacity(0.06), lineWidth: selected ? 2 : 1))
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(entries.count) meetings\(hasNotes ? ", notes" : "")\(hasTranscript ? ", transcript" : "")\(hasSummary ? ", summary" : "")")
    }

    var background: Color {
        if selected { return Brand.green.opacity(0.08) }
        if hover { return Color.primary.opacity(0.06) }
        return scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.025)
    }
}

/// Day-detail row: calendar colour bar, time range, title, content badges.
private struct EntryRow: View {
    var entry: HistoryView.DayEntry
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(entry.color).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                        if entry.saved?.occurrence.eventState == .missing { Text("· not in calendar") }
                        if entry.saved?.occurrence.eventState == .cancelled { Text("· cancelled").foregroundStyle(.orange) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if entry.saved?.hasNotes == true { Badge("Notes", "note.text") }
                    if (entry.saved?.transcriptSegments ?? 0) > 0 { Badge("Transcript", "waveform") }
                    if (entry.saved?.summaryCount ?? 0) > 0 { Badge("Summary", "text.alignleft") }
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(hover ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(entry.title), \(entry.start.formatted(date: .omitted, time: .shortened)), open notes")
    }
}
