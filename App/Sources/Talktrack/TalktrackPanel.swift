import AppKit
import MeetingCore
import MeetingData
import QuartzCore
import SwiftUI

/// Floating teleprompter (§16). Uses the same document/revision machinery as notes.
@MainActor
final class TalktrackModel: ObservableObject {
    @Published var editing = false { didSet { if editing { pause() } } }
    @Published var playing = false
    @Published var title = ""
    @Published var isOccurrenceCopy = false
    @Published var showShareInfo = false
    let editor: DocumentEditorModel
    let settings: AppSettings
    var scrollToTop: (() -> Void)?
    var notebookID: UUID?
    var occurrenceID: UUID?

    init(services: AppServices) {
        editor = DocumentEditorModel(store: services.store)
        settings = services.settings
    }

    func pause() { playing = false }
}

@MainActor
final class TalktrackPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: TalktrackModel
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
        model = TalktrackModel(services: services)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.title = "Talktrack"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Borderless look: our own rounded dark surface and close button; the system buttons are hidden.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = services.settings.talktrackPinned
        panel.level = services.settings.talktrackPinned ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 480, height: 220)
        panel.setFrameAutosaveName("TalktrackPanel2")
        if !panel.setFrameUsingName("TalktrackPanel2") { panel.center() }
        panel.contentView = NSHostingView(rootView: TalktrackView(model: model, settings: services.settings, onPin: { [weak self] pinned in
            self?.panel.isFloatingPanel = pinned
            self?.panel.level = pinned ? .floating : .normal
        }, onClose: { [weak self] in self?.hide() }))
    }

    var isVisible: Bool { panel.isVisible }
    var hasDocument: Bool { model.editor.key != nil }

    func open(notebookID: UUID, occurrenceID: UUID, title: String) {
        model.pause() // changing documents pauses scrolling (§16.2)
        model.title = title
        model.notebookID = notebookID
        model.occurrenceID = occurrenceID
        Task {
            let occKey = DocumentKey(scope: .occurrence(notebookID: notebookID, occurrenceID: occurrenceID), kind: .talktrack)
            let hasCopy = ((try? await services.store.document(occKey))?.revision ?? 0) > 0
            model.isOccurrenceCopy = hasCopy
            await model.editor.load(hasCopy ? occKey : DocumentKey(scope: .series(notebookID: notebookID), kind: .talktrack))
            if model.editor.text.isEmpty { model.editing = true }
            show()
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        model.pause()
        Task { await model.editor.flush() }
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.pause()
        Task { await model.editor.flush() }
    }
}

/// Dark, borderless teleprompter: header with scope and round icon buttons, faded reading area with a reading guide,
/// and a floating control capsule.
struct TalktrackView: View {
    @ObservedObject var model: TalktrackModel
    @ObservedObject var settings: AppSettings
    var onPin: (Bool) -> Void
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                content
            }
            controls.padding(.bottom, 12)
        }
        .background(
            ZStack {
                if !reduceTransparency { Rectangle().fill(.ultraThinMaterial) }
                Color.black.opacity(reduceTransparency ? 0.95 : 0.78)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    var header: some View {
        HStack(spacing: 8) {
            Circle().fill(model.playing ? Brand.green : Color.white.opacity(0.25)).frame(width: 8, height: 8)
                .accessibilityLabel(model.playing ? "Scrolling" : "Paused")
            Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(model.isOccurrenceCopy ? "This occurrence" : "Series script")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.12), in: Capsule())
                .accessibilityLabel(model.isOccurrenceCopy ? "Editing this occurrence's copy" : "Editing the shared series script")
            Spacer()
            RoundIconButton(symbol: model.editing ? "checkmark" : "pencil", active: model.editing,
                            help: model.editing ? "Done editing" : "Edit script (pauses scrolling)") { model.editing.toggle() }
            RoundIconButton(symbol: settings.talktrackPinned ? "pin.fill" : "pin", active: settings.talktrackPinned,
                            help: settings.talktrackPinned ? "Unpin" : "Keep above other windows") {
                settings.talktrackPinned.toggle(); onPin(settings.talktrackPinned)
            }
            RoundIconButton(symbol: "rectangle.on.rectangle", active: model.showShareInfo, help: "Screen sharing") { model.showShareInfo.toggle() }
                .popover(isPresented: $model.showShareInfo) {
                    Text("A floating panel can appear when you share your entire screen or record it. Share a single window instead if your meeting app supports it, or set a “Hide Talktrack” shortcut in Settings › General to hide it quickly.")
                        .font(.system(size: 12)).frame(width: 280).padding()
                }
            RoundIconButton(symbol: "xmark", active: false, help: "Close Talktrack", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .foregroundStyle(.white)
    }

    @ViewBuilder var content: some View {
        if model.editing {
            PlainTextEditor(text: Binding(get: { model.editor.text }, set: { model.editor.text = $0 }), fontSize: CGFloat(settings.talktrackFontSize),
                            onFocusLost: { Task { await model.editor.flush() } }, accessibilityLabel: "Talktrack script")
                .padding(8)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 70)
        } else {
            ZStack {
                TeleprompterView(text: model.editor.text, fontSize: CGFloat(settings.talktrackFontSize), lineSpacing: CGFloat(settings.talktrackLineSpacing),
                                 speed: settings.talktrackSpeed, playing: $model.playing, reduceMotion: reduceMotion,
                                 positionKey: positionKey, registerTop: { model.scrollToTop = $0 })
                    .padding(.horizontal, 10)
                    // Soft fades at the top and bottom keep the eye on the reading line.
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                                 .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                // Reading guide at one third of the height.
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 2).fill(Brand.green.opacity(0.7)).frame(width: 4, height: CGFloat(settings.talktrackFontSize) * 1.3)
                        .position(x: 7, y: g.size.height / 3)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if model.editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.white.opacity(0.4))
                        Text("No script yet").foregroundStyle(.white.opacity(0.7))
                        Button("Write Script") { model.editing = true }.buttonStyle(.borderedProminent).tint(Brand.green)
                    }
                }
            }
        }
    }

    var controls: some View {
        HStack(spacing: 12) {
            Button { model.playing.toggle() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Brand.green, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.editing)
            .opacity(model.editing ? 0.4 : 1)
            .accessibilityLabel(model.playing ? "Pause scrolling" : "Start scrolling")
            RoundIconButton(symbol: "arrow.up.to.line", active: false, help: "Return to top") { model.pause(); model.scrollToTop?() }
            divider
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Slider(value: $settings.talktrackSpeed, in: 8...80).frame(width: 90).controlSize(.small)
                    .accessibilityLabel("Scroll speed").accessibilityValue("\(Int(settings.talktrackSpeed)) points per second")
                Image(systemName: "hare.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Text("\(Int(settings.talktrackSpeed))").font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 20)
            }
            divider
            stepper(icon: "textformat.size", value: $settings.talktrackFontSize, range: 16...48, step: 2, label: "Font size")
            stepper(icon: "line.3.horizontal", value: $settings.talktrackLineSpacing, range: 0...24, step: 2, label: "Line spacing")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
        .overlay(alignment: .trailing) {
            SaveStatusView(status: model.editor.status).labelStyle(.iconOnly).offset(x: 28)
        }
    }

    var divider: some View { Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 18) }

    func stepper(icon: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack(spacing: 4) {
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: { Image(systemName: "minus").frame(width: 18, height: 18) }
                .accessibilityLabel("Decrease \(label)")
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            Text("\(Int(value.wrappedValue))").font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 18)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
                .accessibilityLabel("Increase \(label)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .bold))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    var positionKey: String {
        guard let k = model.editor.key else { return "" }
        return "talktrack.pos.\(k.scope.notebookID)-\(k.scope.occurrenceID?.uuidString ?? "series")-\(model.editor.revision)"
    }
}

struct RoundIconButton: View {
    var symbol: String
    var active: Bool
    var help: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(active ? Brand.green.opacity(0.35) : Color.white.opacity(hover ? 0.18 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Display-linked auto-scroll driven by elapsed monotonic time, so speed is independent of refresh rate (§16.2).
/// The display link runs only while visible and playing.
struct TeleprompterView: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var speed: Double
    @Binding var playing: Bool
    var reduceMotion: Bool
    var positionKey: String
    var registerTop: (@escaping () -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 40)
        tv.delegate = context.coordinator
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.userScrolled),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        registerTop { [weak coord = context.coordinator] in coord?.scrollTo(0, persist: true, resetSaved: true) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let tv = scroll.documentView as! NSTextView
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        if tv.textStorage?.isEqual(to: attr) == false {
            tv.textStorage?.setAttributedString(attr)
            if c.restoredKey != positionKey {
                c.restoredKey = positionKey
                let saved = UserDefaults.standard.double(forKey: positionKey)
                DispatchQueue.main.async { c.scrollTo(saved, persist: false) }
            }
        }
        c.setPlaying(playing, view: scroll)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.setPlaying(false, view: scroll)
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TeleprompterView
        weak var scroll: NSScrollView?
        private var link: CADisplayLink?
        private var lastTime: CFTimeInterval?
        private var offset: CGFloat = 0
        private var discreteAccumulator: CGFloat = 0
        var restoredKey = ""

        init(_ p: TeleprompterView) { parent = p }

        func setPlaying(_ on: Bool, view: NSView) {
            if on, link == nil, view.window?.isVisible == true {
                lastTime = nil
                offset = scroll?.contentView.bounds.origin.y ?? 0
                let l = view.displayLink(target: self, selector: #selector(step(_:)))
                l.add(to: .main, forMode: .common)
                link = l
            } else if !on, let l = link {
                l.invalidate()
                link = nil
                persist()
            }
        }

        @objc func step(_ l: CADisplayLink) {
            guard let scroll, scroll.window?.isVisible == true else { parent.playing = false; return }
            let now = l.timestamp
            defer { lastTime = now }
            guard let last = lastTime else { return }
            let dt = now - last
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            if parent.reduceMotion {
                let delta = CGFloat(parent.speed * dt)
                // Reduce Motion: advance in whole-line steps instead of continuous motion.
                discreteAccumulator += delta
                let lineH = parent.fontSize + parent.lineSpacing
                guard discreteAccumulator >= lineH else { return }
                offset += lineH; discreteAccumulator -= lineH
                if offset >= maxY { offset = maxY; parent.playing = false }
            } else {
                let r = TeleprompterScroll.advance(offset: offset, speed: parent.speed, elapsed: dt, maxOffset: maxY)
                offset = r.offset
                if r.reachedEnd { parent.playing = false }
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func scrollTo(_ y: CGFloat, persist p: Bool, resetSaved: Bool = false) {
            guard let scroll else { return }
            offset = y
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            if resetSaved { UserDefaults.standard.removeObject(forKey: parent.positionKey) }
            if p { persist() }
        }

        func persist() {
            guard !parent.positionKey.isEmpty, let y = scroll?.contentView.bounds.origin.y else { return }
            UserDefaults.standard.set(Double(y), forKey: parent.positionKey)
        }

        /// Manual scrolling takes over: auto-scroll pauses.
        @objc func userScrolled() { if parent.playing { parent.playing = false } }

        /// Selecting text pauses auto-scroll (§16.2).
        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView, tv.selectedRange().length > 0, parent.playing else { return }
            parent.playing = false
        }
    }
}
