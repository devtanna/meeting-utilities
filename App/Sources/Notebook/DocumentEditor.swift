import AppKit
import MeetingCore
import MeetingData
import SwiftUI

/// Save pipeline for one document (§9.2): ~300 ms debounce, flush on focus loss / close / switch / quit,
/// revision-guarded optimistic saves, and a visible Saving / Saved / error indicator.
@MainActor
final class DocumentEditorModel: ObservableObject {
    enum Status: Equatable { case idle, saving, saved, error(String), conflict }

    @Published var text: String = "" { didSet { if !loading && text != oldValue { scheduleSave() } } }
    @Published private(set) var status: Status = .idle
    @Published private(set) var key: DocumentKey?
    @Published private(set) var revision = 0
    @Published private(set) var conflictText: String?
    private var loading = false
    private var saveTask: Task<Void, Never>?
    private var lastSaved = ""
    private let store: MeetingStore
    var onSaved: (() -> Void)?

    init(store: MeetingStore) {
        self.store = store
        EditorRegistry.shared.register(self) { [weak self] in await self?.flush() }
    }

    func unregister() { EditorRegistry.shared.unregister(self) }

    var isDirty: Bool { text != lastSaved }

    /// Switches document. Pending text for the previous document is flushed against *its* key first, so a late
    /// save can never overwrite the newly selected meeting (§9.2).
    func load(_ newKey: DocumentKey) async {
        if newKey == key { return }
        await flush()
        loading = true
        key = newKey
        let snap = (try? await store.document(newKey)) ?? DocumentSnapshot(key: newKey, id: nil, body: "", revision: 0, updatedAt: nil)
        guard key == newKey else { loading = false; return }
        text = snap.body
        lastSaved = snap.body
        revision = snap.revision
        status = snap.revision > 0 ? .saved : .idle
        conflictText = nil
        loading = false
    }

    func reload() async {
        guard let key, !isDirty else { return }
        loading = true
        if let snap = try? await store.document(key) { text = snap.body; lastSaved = snap.body; revision = snap.revision }
        loading = false
    }

    private func scheduleSave() {
        EditorRegistry.shared.setDirty(self, true)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        saveTask?.cancel()
        guard let key, text != lastSaved else { EditorRegistry.shared.setDirty(self, false); return }
        // Lazy creation: an empty, never-created document is not written (§9.1).
        if revision == 0 && text.isEmpty { return }
        let body = text, base = revision
        status = .saving
        do {
            let receipt = try await store.save(DocumentRevision(key: key, baseRevision: base, body: body))
            guard self.key == key else { return }   // user switched meanwhile; the old doc was still saved correctly
            revision = receipt.revision
            lastSaved = body
            if let other = receipt.conflictingBody {
                conflictText = other
                status = .conflict
            } else {
                status = .saved
            }
            if text == lastSaved { EditorRegistry.shared.setDirty(self, false) }
            onSaved?()
        } catch {
            // Keep the editor text in memory and offer export (§22.2).
            status = .error(AppErrorCode.databaseUnwritable.message)
            Log.persistence.error("document save failed")
        }
    }
}

struct SaveStatusView: View {
    var status: DocumentEditorModel.Status
    var body: some View {
        Group {
            switch status {
            case .idle: Text(" ")
            case .saving: Label("Saving", systemImage: "arrow.triangle.2.circlepath")
            case .saved: Label("Saved", systemImage: "checkmark")
            case .error(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            case .conflict: Label("Edited elsewhere — other version kept in history", systemImage: "exclamationmark.2").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityLabel("Save status")
    }
}

/// NSTextView-backed plain-text editor: native undo, selection, and long-document performance (§5.4).
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var isEditable = true
    var onFocusLost: () -> Void = {}
    var onSelectionOrEdit: () -> Void = {}
    var accessibilityLabel = "Notes"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        tv.isEditable = isEditable
        tv.setAccessibilityLabel(accessibilityLabel)
        scroll.drawsBackground = false
        tv.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        tv.isEditable = isEditable
        if tv.font?.pointSize != fontSize { tv.font = .systemFont(ofSize: fontSize) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ p: PlainTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onSelectionOrEdit()
        }
        func textDidEndEditing(_ n: Notification) { parent.onFocusLost() }
        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView, tv.selectedRange().length > 0 else { return }
            parent.onSelectionOrEdit()
        }
    }
}

/// Read-only rich text in one NSTextView: native click-drag, Shift-click, double/triple-click, ⌘A and ⌘C across
/// the whole document (SwiftUI's per-Text selection can't cross lines).
struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString
    var accessibilityLabel = "Text"

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.setAccessibilityLabel(accessibilityLabel)
        tv.textStorage?.setAttributedString(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        // Reloads happen on every database change; only replace text that actually changed, keeping the selection.
        guard tv.attributedString() != text else { return }
        let sel = tv.selectedRanges
        tv.textStorage?.setAttributedString(text)
        let kept = sel.filter { $0.rangeValue.upperBound <= text.length }
        tv.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept   // must never be empty
    }
}

/// Safe Markdown subset preview: no HTML execution, no remote images (§5.4, §14.6).
struct MarkdownPreview: View {
    var text: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") { inline(String(trimmed.dropFirst(4))).font(.headline) }
        else if trimmed.hasPrefix("## ") { inline(String(trimmed.dropFirst(3))).font(.title3.bold()) }
        else if trimmed.hasPrefix("# ") { inline(String(trimmed.dropFirst(2))).font(.title2.bold()) }
        else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { HStack(alignment: .top) { Text("•"); inline(String(trimmed.dropFirst(2))) } }
        else if trimmed.isEmpty { Text(" ").font(.system(size: 4)) }
        else { inline(line) }
    }

    func inline(_ s: String) -> Text {
        // Inline-only Markdown → AttributedString; links are displayed, never fetched.
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }
}
