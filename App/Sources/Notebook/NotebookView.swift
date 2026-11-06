import AppKit
import Combine
import MeetingCore
import MeetingData
import SwiftUI
import UniformTypeIdentifiers

enum NotebookTab: String, CaseIterable, Identifiable {
    case notes = "Notes", transcript = "Transcript", summary = "Summary", talktrack = "Talktrack"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .notes: "note.text"
        case .transcript: "waveform"
        case .summary: "text.alignleft"
        case .talktrack: "text.bubble"
        }
    }
}

@MainActor
final class NotebookViewModel: ObservableObject {
    @Published var notebook: NotebookRecord?
    @Published var occurrence: OccurrenceRecord?
    @Published var history: [OccurrenceSummary] = []
    @Published var transcript: [(session: MeetingSessionRecord, segments: [TranscriptSegmentRecord])] = []
    @Published var summaries: [SummaryVersionRecord] = []
    @Published var tab: NotebookTab = .notes
    @Published var reconciliation: ReconciliationState = .linked
    @Published var suggestions: [NotebookRecord] = []
    @Published var message: String?
    @Published var talktrackIsOccurrenceCopy = false
    let seriesNotes: DocumentEditorModel
    let occurrenceNotes: DocumentEditorModel
    let talktrack: DocumentEditorModel
    let services: AppServices
    private var observer: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        seriesNotes = DocumentEditorModel(store: services.store)
        occurrenceNotes = DocumentEditorModel(store: services.store)
        talktrack = DocumentEditorModel(store: services.store)
        observer = NotificationCenter.default.addObserver(forName: AppDatabase.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    func close() async {
        await seriesNotes.flush(); await occurrenceNotes.flush(); await talktrack.flush()
        seriesNotes.unregister(); occurrenceNotes.unregister(); talktrack.unregister()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func open(occurrenceID: UUID, resolved: ResolvedOccurrence? = nil) async {
        let signpost = Log.signposter.beginInterval("note.open")
        defer { Log.signposter.endInterval("note.open", signpost) }
        guard let occ = try? await services.store.occurrence(occurrenceID), let nb = try? await services.store.notebook(occ.notebookID) else {
            message = "This meeting's notebook could not be found."; return
        }
        if let resolved { reconciliation = resolved.reconciliation; suggestions = resolved.suggestions }
        notebook = nb
        occurrence = occ
        await seriesNotes.load(DocumentKey(scope: .series(notebookID: nb.id), kind: .notes))
        await occurrenceNotes.load(DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .notes))
        await loadTalktrack()
        await reload()
        // A date with a saved transcript but no notes opens on the transcript rather than an empty page.
        if tab == .notes, occurrenceNotes.text.isEmpty, transcript.contains(where: { !$0.segments.isEmpty }) { tab = .transcript }
    }

    func loadTalktrack() async {
        guard let nb = notebook, let occ = occurrence else { return }
        let occKey = DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .talktrack)
        let hasCopy = ((try? await services.store.document(occKey))?.revision ?? 0) > 0
        talktrackIsOccurrenceCopy = hasCopy
        await talktrack.load(hasCopy ? occKey : DocumentKey(scope: .series(notebookID: nb.id), kind: .talktrack))
    }

    /// "Customize this occurrence" makes a copy that no longer follows the series script (§16.1).
    func customizeTalktrack() async {
        guard let nb = notebook, let occ = occurrence else { return }
        await talktrack.flush()
        let body = talktrack.text
        let key = DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .talktrack)
        _ = try? await services.store.save(DocumentRevision(key: key, baseRevision: 0, body: body.isEmpty ? " " : body))
        await loadTalktrack()
    }

    func useSeriesTalktrack() async {
        guard let nb = notebook, let occ = occurrence else { return }
        await talktrack.flush()
        try? await services.store.deleteDocument(DocumentKey(scope: .occurrence(notebookID: nb.id, occurrenceID: occ.id), kind: .talktrack))
        await loadTalktrack()
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard let nb = notebook, let occ = occurrence else { return }
        history = (try? await services.store.history(notebookID: nb.id, before: nil, limit: 50)) ?? []
        transcript = (try? await services.store.transcript(occurrenceID: occ.id)) ?? []
        summaries = (try? await services.store.summaries(occurrenceID: occ.id)) ?? []
        if let fresh = try? await services.store.notebook(nb.id) { notebook = fresh }
        await seriesNotes.reload(); await occurrenceNotes.reload()
    }

    func copyPreviousNotes() async {
        guard let nb = notebook, let occ = occurrence else { return }
        guard let (prev, body) = try? await services.store.previousNotes(notebookID: nb.id, before: occ.start) else {
            message = "No earlier notes in this notebook."; return
        }
        let df = DateFormatter(); df.dateStyle = .medium
        let header = "— Copied from \(df.string(from: prev.start)) —\n"
        occurrenceNotes.text = occurrenceNotes.text.isEmpty ? header + body : occurrenceNotes.text + "\n\n" + header + body
    }
}

struct NotebookView: View {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var summaries: SummaryCoordinator
    @State private var showDeleteOccurrence = false
    @State private var showDeleteNotebook = false
    @State private var linkTarget: UUID?
    @State private var preview = false
    @State private var seriesExpanded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Floating sidebar + page, matching Settings and Calendar and Notes (transparent 52 pt title band, no toolbar blur).
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
                .padding(8)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 860, minHeight: 560)
        .alert("Delete this meeting's content?", isPresented: $showDeleteOccurrence) {
            Button("Delete", role: .destructive) { Task { if let o = model.occurrence { try? await model.services.store.deleteOccurrenceContent(o.id); await model.reload() } } }
        } message: {
            Text("Deletes notes, Talktrack copy, transcripts and summaries for this date only. Your calendar event is not changed. \(model.services.store.hasBackups ? "An app-managed pre-migration backup may still contain this content; remove it in Settings › Data." : "")")
        }
        .alert("Delete the whole notebook?", isPresented: $showDeleteNotebook) {
            Button("Delete Notebook", role: .destructive) {
                Task { if let n = model.notebook { try? await model.services.store.deleteNotebook(n.id); model.services.windows.closeNotebook(n.id) } }
            }
        } message: {
            Text("Deletes series notes and every dated entry, transcript and summary in this notebook. Calendar events are not changed. \(model.services.store.hasBackups ? "App-managed backups may still contain it." : "")")
        }
    }

    // MARK: Sidebar (dated entries)

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 30) // traffic lights
            if let nb = model.notebook {
                HStack(spacing: 10) {
                    IconTile(symbol: nb.kind == .series ? "repeat" : "note.text", color: .orange, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(nb.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(nb.kind == .series ? "Series notebook" : "Single event").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            Text("Dated entries").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.history) { h in entryRow(h) }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    func entryRow(_ h: OccurrenceSummary) -> some View {
        let selected = model.occurrence?.id == h.occurrence.id
        return Button { Task { await model.open(occurrenceID: h.occurrence.id) } } label: {
            HStack(spacing: 10) {
                DateTile(size: 32, date: h.occurrence.start)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.occurrence.start.formatted(.dateTime.weekday(.wide))).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 5) {
                        Text(h.occurrence.start.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                        if h.occurrence.eventState == .cancelled { Text("Cancelled").foregroundStyle(.orange) }
                        if h.occurrence.eventState == .missing { Text("Removed").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    if h.hasNotes { Badge("Notes", "note.text") }
                    if h.transcriptSegments > 0 { Badge("Transcript", "waveform") }
                    if h.summaryCount > 0 { Badge("Summary", "text.alignleft") }
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Detail

    @ViewBuilder var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if model.notebook != nil { actionsMenu }
            }
            .frame(height: 52)
            .padding(.horizontal, 16)
            if let nb = model.notebook, let occ = model.occurrence {
                VStack(alignment: .leading, spacing: 14) {
                    header(nb, occ)
                    if model.reconciliation == .ambiguous { repairBanner }
                    if let m = model.message { Text(m).foregroundStyle(.secondary).font(.callout) }
                    if let a = coordinator.active, a.occurrenceID == occ.id {
                        CaptureIndicator(state: a, coordinator: coordinator, services: model.services)
                    }
                    seriesNotesCard
                    tabBar
                    Group {
                        switch model.tab {
                        case .notes: notesTab
                        case .transcript: ContentCard { TranscriptTab(transcript: model.transcript) }
                        case .summary: ContentCard { SummaryTab(model: model, summaries: summaries).padding(10) }
                        case .talktrack: talktrackTab
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "note.text")
            }
        }
    }

    func header(_ nb: NotebookRecord, _ occ: OccurrenceRecord) -> some View {
        HStack(alignment: .center, spacing: 14) {
            DateTile(size: 54, date: occ.start)
            VStack(alignment: .leading, spacing: 3) {
                Text(occ.titleSnapshot).font(.system(size: 24, weight: .bold)).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 6) {
                    Text(occ.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    Text("·")
                    Text("\(occ.start.formatted(date: .omitted, time: .shortened))–\(occ.end.formatted(date: .omitted, time: .shortened))").monospacedDigit()
                    if let tz = occ.timeZoneID, tz != TimeZone.current.identifier { Text("· \(tz)") }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if coordinator.active?.occurrenceID != occ.id { transcriptionButton(occ) }
        }
    }

    func transcriptionButton(_ occ: OccurrenceRecord) -> some View {
        let ready = model.services.models.isReady(.speechToText)
        return Button {
            guard let nb = model.notebook else { return }
            let ended = occ.end <= Date()
            Task { await coordinator.startManual(occurrenceID: occ.id, notebookID: nb.id, title: occ.titleSnapshot, calendarEnd: occ.end, duration: ended ? 30 * 60 : nil) }
        } label: {
            Label("Start Transcription", systemImage: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(ready && !coordinator.isCapturing ? Brand.green : Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(ready && !coordinator.isCapturing ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isCapturing || !ready)
        .help(ready ? (occ.end <= Date() ? "Meeting ended — a manual session runs 30 min unless extended." : "Transcribes your microphone and this Mac's sound output. Audio is never saved.")
                    : "Install the speech model in Settings › Models first.")
    }

    var seriesNotesCard: some View {
        SettingsCard {
            Button { withAnimation(.easeInOut(duration: 0.15)) { seriesExpanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(seriesExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Series notes").font(.system(size: 13, weight: .medium))
                        Text("Shared by every occurrence of this meeting").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SaveStatusView(status: model.seriesNotes.status)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(seriesExpanded ? "Collapse series notes" : "Expand series notes")
            if seriesExpanded {
                Divider()
                PlainTextEditor(text: Binding(get: { model.seriesNotes.text }, set: { model.seriesNotes.text = $0 }),
                                onFocusLost: { Task { await model.seriesNotes.flush() } }, accessibilityLabel: "Series notes")
                    .frame(minHeight: 80, maxHeight: 150)
                    .padding(.horizontal, 6)
            }
        }
    }

    /// Pill-style tab bar.
    var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(NotebookTab.allCases) { t in
                let selected = model.tab == t
                Button { model.tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: Capsule())
                        .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1, y: 0.5)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    var repairBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This event could belong to an existing notebook. Nothing was merged automatically.", systemImage: "link.badge.plus")
            HStack {
                Picker("Link to", selection: $linkTarget) {
                    Text("Choose notebook…").tag(UUID?.none)
                    ForEach(model.suggestions) { Text($0.displayTitle).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Button("Link to Existing Notebook") {
                    guard let t = linkTarget, let occ = model.occurrence else { return }
                    Task {
                        if (try? await model.services.store.linkToExistingNotebook(occurrenceID: occ.id, targetNotebookID: t)) != nil {
                            model.reconciliation = .linked
                            model.message = "Linked. You can undo this in Settings › Data."
                            await model.open(occurrenceID: occ.id)
                        }
                    }
                }
                .disabled(linkTarget == nil)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var notesTab: some View {
        ContentCard {
            HStack(spacing: 8) {
                Text("Notes for this date").font(.system(size: 13, weight: .semibold))
                Spacer()
                PillToggle(title: "Preview", icon: "eye", isOn: $preview)
                PillButton(title: "Copy Previous Notes", icon: "doc.on.doc") { Task { await model.copyPreviousNotes() } }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if preview {
                MarkdownPreview(text: model.occurrenceNotes.text).padding(.horizontal, 6)
            } else {
                PlainTextEditor(text: Binding(get: { model.occurrenceNotes.text }, set: { model.occurrenceNotes.text = $0 }),
                                onFocusLost: { Task { await model.occurrenceNotes.flush() } }, accessibilityLabel: "Occurrence notes")
                    .padding(.horizontal, 6)
            }
            Divider()
            HStack { Text("Markdown supported").font(.system(size: 11)).foregroundStyle(.tertiary); Spacer(); SaveStatusView(status: model.occurrenceNotes.status) }
                .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    var talktrackTab: some View {
        ContentCard {
            HStack(spacing: 8) {
                Text(model.talktrackIsOccurrenceCopy ? "This occurrence's script" : "Series script").font(.system(size: 13, weight: .semibold))
                Text(model.talktrackIsOccurrenceCopy ? "Custom" : "Shared").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                if model.talktrackIsOccurrenceCopy {
                    PillButton(title: "Use Series Script", icon: "arrow.uturn.backward") { Task { await model.useSeriesTalktrack() } }
                } else {
                    PillButton(title: "Customize This Occurrence", icon: "square.and.pencil") { Task { await model.customizeTalktrack() } }
                }
                PillButton(title: "Open Teleprompter", icon: "play.rectangle", prominent: true) {
                    if let nb = model.notebook, let occ = model.occurrence { model.services.windows.openTalktrack(notebookID: nb.id, occurrenceID: occ.id, title: occ.titleSnapshot) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            PlainTextEditor(text: Binding(get: { model.talktrack.text }, set: { model.talktrack.text = $0 }), fontSize: 15,
                            onFocusLost: { Task { await model.talktrack.flush() } }, accessibilityLabel: "Talktrack script")
                .padding(.horizontal, 6)
            Divider()
            HStack { Spacer(); SaveStatusView(status: model.talktrack.status) }.padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    var actionsMenu: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Export This Date (Markdown + JSON)…") { exportOccurrence() }
                Button("Export Notebook (Markdown + JSON)…") { exportNotebook() }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            Menu {
                Button("Delete This Date's Content…", role: .destructive) { showDeleteOccurrence = true }
                Button("Delete Notebook…", role: .destructive) { showDeleteNotebook = true }
            } label: { Label("Delete", systemImage: "trash") }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .font(.system(size: 12))
    }

    func exportOccurrence() {
        guard let occ = model.occurrence else { return }
        Task {
            guard let bundle = try? await model.services.store.exportOccurrenceBundle(occ.id) else { return }
            save(bundle, name: "\(occ.titleSnapshot) \(occ.start.formatted(.iso8601.year().month().day()))")
        }
    }

    func exportNotebook() {
        guard let nb = model.notebook else { return }
        Task {
            guard let bundle = try? await model.services.store.exportNotebook(nb.id) else { return }
            save(bundle, name: nb.displayTitle)
        }
    }

    func save(_ bundle: ExportBundle, name: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Exports are written where you choose and are outside Meeting Utility's local data."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try? bundle.markdown.write(to: dir.appendingPathComponent("\(safe).md"), atomically: true, encoding: .utf8)
        try? bundle.json.write(to: dir.appendingPathComponent("\(safe).json"))
    }
}

struct Badge: View {
    var label: String
    var icon: String
    init(_ label: String, _ icon: String) { self.label = label; self.icon = icon }
    var body: some View {
        Label(label, systemImage: icon).labelStyle(.iconOnly).font(.caption2).foregroundStyle(.secondary)
            .help(label).accessibilityLabel(label)
    }
}

/// The saved raw transcript for one date: `[mm:ss]` stamps beside readable text, grouped by capture session.
/// Summaries are a separate, optional step on the Summary tab.
struct TranscriptTab: View {
    var transcript: [(session: MeetingSessionRecord, segments: [TranscriptSegmentRecord])]
    @State private var copied = false

    var speech: [TranscriptSegmentRecord] { transcript.flatMap(\.segments).filter { $0.kind != .gap } }
    /// Speaker labels only help when both the microphone and other participants were captured.
    var showSources: Bool { Set(speech.map(\.source)).count > 1 }
    var useHours: Bool { transcript.flatMap(\.segments).contains { $0.startOffsetMs >= 3_600_000 } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Transcript").font(.system(size: 13, weight: .semibold))
            if !speech.isEmpty {
                Text("\(speech.count) \(speech.count == 1 ? "line" : "lines")").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            PillButton(title: copied ? "Copied" : "Copy Transcript", icon: copied ? "checkmark" : "doc.on.doc") { copy() }
                .disabled(speech.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        Divider()
        if transcript.isEmpty {
            ContentUnavailableView("No transcript", systemImage: "waveform", description: Text("Start transcription from the agenda, a notification Join, or the button above."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcript, id: \.session.id) { entry in
                        if transcript.count > 1 || entry.segments.isEmpty { sessionHeader(entry.session, empty: entry.segments.isEmpty) }
                        ForEach(entry.segments) { seg in row(seg) }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
    }

    func sessionHeader(_ s: MeetingSessionRecord, empty: Bool) -> some View {
        let range = "\(s.actualStart?.formatted(date: .omitted, time: .shortened) ?? "–")–\(s.actualEnd?.formatted(date: .omitted, time: .shortened) ?? "…")"
        return Text("Session \(range) · \(label(s))\(empty ? " · no speech recognized" : "")")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    func row(_ seg: TranscriptSegmentRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("[\(stamp(seg.startOffsetMs))]")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: useHours ? 66 : 48, alignment: .leading)
            if seg.kind == .gap {
                Text("No transcript for \(max(1, (seg.endOffsetMs - seg.startOffsetMs) / 1000)) s (\(seg.sourceLabel))")
                    .font(.system(size: 13)).italic().foregroundStyle(.orange)
            } else {
                (showSources ? Text("\(seg.sourceLabel)  ").font(.system(size: 12, weight: .semibold)).foregroundColor(seg.source == "microphone" ? .accentColor : .purple) : Text(""))
                    + Text(seg.text).font(.system(size: 14))
            }
        }
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    func copy() {
        let lines = speech.map { "[\(stamp($0.startOffsetMs))] \(showSources ? "\($0.sourceLabel): " : "")\($0.text)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    func stamp(_ ms: Int) -> String {
        let t = ms / 1000
        return useHours ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
    func label(_ s: MeetingSessionRecord) -> String {
        switch s.state {
        case .interrupted: "interrupted"
        case .stopped: s.stopReason == .scheduledEnd ? "stopped at scheduled end" : s.stopReason == .user ? "stopped" : "stopped (\(s.stopReason?.rawValue ?? ""))"
        case .failed: "failed"
        default: s.state.rawValue
        }
    }
}

struct SummaryTab: View {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var summaries: SummaryCoordinator
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmRegenerate = false

    var body: some View {
        let occID = model.occurrence?.id
        let state = occID.flatMap { summaries.states[$0] } ?? .notRequested
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let latest = model.summaries.first {
                    Text("\(latest.userEdited ? "Edited" : "Generated") \(latest.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(latest.modelID)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                stateLabel(state, occID)
                if state == .queued || state == .generating || state == .loadingModel {
                    Button("Cancel") { if let occID { summaries.cancel(occurrenceID: occID) } }
                } else {
                    Button(model.summaries.isEmpty ? "Summarize" : "Regenerate") {
                        if model.summaries.first?.userEdited == true { confirmRegenerate = true } else { regenerate() }
                    }
                    .disabled(model.transcript.flatMap(\.segments).isEmpty || !model.services.models.isReady(.summary))
                    .help(model.services.models.isReady(.summary) ? "Runs locally with the summary model." : "Install the summary model in Settings › Models.")
                    if let latest = model.summaries.first {
                        Button(editing ? "Save Edit" : "Edit") {
                            if editing, let nb = model.notebook, let edited = SummaryPrompt.decode(draft) {
                                Task { await summaries.saveEdited(edited, basedOn: latest, notebookID: nb.id) }
                            } else {
                                draft = latest.result.encoded()
                            }
                            editing.toggle()
                        }
                    }
                }
            }
            if editing {
                Text("Edit the JSON fields directly; your edit is saved as a new version and never overwritten without asking.").font(.caption).foregroundStyle(.secondary)
                PlainTextEditor(text: $draft, fontSize: 12, accessibilityLabel: "Summary JSON").border(.separator)
            } else if let s = model.summaries.first?.result {
                SummaryRenderView(summary: s, segments: model.transcript.flatMap(\.segments))
            } else {
                ContentUnavailableView("No summary yet", systemImage: "text.alignleft", description: Text("Summaries are generated locally from the saved transcript."))
            }
        }
        .confirmationDialog("Replace your edited summary?", isPresented: $confirmRegenerate) {
            Button("Generate New Version") { regenerate() }
        } message: { Text("Your edited version stays in history; the new summary becomes the latest version.") }
    }

    func regenerate() {
        guard let occ = model.occurrence, let nb = model.notebook else { return }
        summaries.retry(occurrenceID: occ.id, notebookID: nb.id)
    }

    @ViewBuilder func stateLabel(_ s: SummaryState, _ occ: UUID?) -> some View {
        let msg = occ.flatMap { summaries.messages[$0] }
        switch s {
        case .queued: Text(summaries.deferredReason ?? "Queued").foregroundStyle(.secondary).font(.caption)
        case .loadingModel: ProgressView().controlSize(.small); Text("Loading model…").font(.caption)
        case .generating: ProgressView().controlSize(.small); Text(msg ?? "Generating…").font(.caption)
        case .failed: Text(msg ?? "Failed").foregroundStyle(.red).font(.caption)
        case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

/// Native rendering of the structured summary; no active content (§14.5).
struct SummaryRenderView: View {
    var summary: SummaryV1
    var segments: [TranscriptSegmentRecord]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !summary.overview.isEmpty { section("Overview") { Text(summary.overview) } }
                if !summary.discussionPoints.isEmpty { section("Discussion points") { bullets(summary.discussionPoints) } }
                if !summary.decisions.isEmpty {
                    section("Decisions") {
                        ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .top) { Text("•"); VStack(alignment: .leading) { Text(d.text); refs(d.sourceSegmentIDs) } }
                        }
                    }
                }
                if !summary.actionItems.isEmpty {
                    section("Action items") {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, a in
                            HStack(alignment: .top) {
                                Image(systemName: "square")
                                VStack(alignment: .leading) {
                                    Text(a.text)
                                    HStack {
                                        Text("Owner: \(a.owner ?? "not stated")").foregroundStyle(a.owner == nil ? .tertiary : .secondary)
                                        Text("Due: \(a.dueDateText ?? "not stated")").foregroundStyle(a.dueDateText == nil ? .tertiary : .secondary)
                                    }.font(.caption)
                                    refs(a.sourceSegmentIDs)
                                }
                            }
                        }
                    }
                }
                if !summary.openQuestions.isEmpty { section("Open questions") { bullets(summary.openQuestions) } }
                if !summary.coverageWarnings.isEmpty {
                    section("Coverage") { ForEach(summary.coverageWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); c() }
    }
    func bullets(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { t in HStack(alignment: .top) { Text("•"); Text(t) } }
    }
    func refs(_ ids: [String]) -> some View {
        let lookup = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ("S\($0.offset + 1)", $0.element) })
        return Text(ids.map { id in lookup[id].map { "\(id) \(stamp($0.startOffsetMs))" } ?? id }.joined(separator: ", "))
            .font(.caption).foregroundStyle(.secondary)
            .help(ids.compactMap { lookup[$0]?.text }.joined(separator: "\n"))
    }
    func stamp(_ ms: Int) -> String { let t = ms / 1000; return String(format: "%02d:%02d", t / 60, t % 60) }
}
