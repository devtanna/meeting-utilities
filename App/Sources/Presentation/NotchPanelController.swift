import AppKit
import Combine
import MeetingCore
import SwiftUI

final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Notch mode: a borderless panel positioned around the camera housing, or a top-centre capsule (§5.3).
@MainActor
final class NotchPanelController: NSObject {
    private unowned let services: AppServices
    private let panel: KeyablePanel
    private let model = NotchViewModel()
    private var outsideMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        self.services = services
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Not shown over fullscreen apps, so fullscreen controls are never covered.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("Meeting Utility notch agenda")
        panel.onEscape = { [weak self] in if self?.model.pinned == false { self?.collapse() } }
        panel.contentView = NSHostingView(rootView: NotchRootView(services: services, model: model, onToggle: { [weak self] in self?.toggle() },
                                                                  onHover: { [weak self] inside in self?.hover(inside) }))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        services.settings.$notchDisplayID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
        model.$pinned.sink { [weak self] _ in DispatchQueue.main.async { self?.updateMonitor() } }.store(in: &cancellables)
        layout()
        panel.orderFrontRegardless()
    }

    var isExpanded: Bool { model.expanded }

    func teardown() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel.orderOut(nil)
    }

    /// Selected display, or the built-in (notched) one, falling back safely when it disappears.
    var screen: NSScreen {
        let id = services.settings.notchDisplayID
        if id != 0, let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func metrics(_ s: NSScreen) -> ScreenMetrics {
        ScreenMetrics(frame: s.frame, visibleFrame: s.visibleFrame, safeAreaTop: s.safeAreaInsets.top,
                      auxiliaryTopLeft: s.auxiliaryTopLeftArea, auxiliaryTopRight: s.auxiliaryTopRightArea)
    }

    func layout() {
        let l = NotchGeometry.layout(metrics(screen), expandedHeight: 640)
        model.layout = l
        let frame = model.expanded ? l.compact.union(l.expanded) : l.compact
        panel.setFrame(frame, display: true, animate: false)
    }

    func toggle() { model.expanded ? collapse() : expand() }

    func expand() {
        services.calendar.refreshIfOld()
        model.expanded = true
        layout()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        updateMonitor()
    }

    func collapse() {
        model.expanded = false
        model.pinned = false
        layout()
        updateMonitor()
    }

    private func hover(_ inside: Bool) {
        guard services.settings.notchHoverExpands else { return }
        if inside && !model.expanded { expand() }
    }

    /// Unpinned: outside click dismisses (§5.3).
    private func updateMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        guard model.expanded, !model.pinned else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    func updateCompact() { model.compactText = services.presentation.compactText(); model.capturing = services.coordinator.isCapturing }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var layout: NotchLayout?
    @Published var compactText = ""
    @Published var capturing = false
}

struct NotchRootView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var model: NotchViewModel
    var onToggle: () -> Void
    var onHover: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 4) {
            compact
            if model.expanded {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless)
                            .help(model.pinned ? "Unpin (Escape or outside click will close)" : "Pin to keep open")
                            .accessibilityLabel(model.pinned ? "Unpin agenda" : "Pin agenda")
                            .padding(.trailing, 8).padding(.top, 4)
                    }
                    AgendaRoot(services: services, onClose: onToggle)
                }
                .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial),
                            in: RoundedRectangle(cornerRadius: 12))
                .frame(width: NotchGeometry.expandedWidth)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder var compact: some View {
        let l = model.layout
        if let l, l.isNotched, let notch = l.notchRect {
            // Text sits beside the housing; the physical cutout is never drawn over.
            let left = notch.minX - l.compact.minX, right = l.compact.maxX - notch.maxX
            HStack(spacing: 0) {
                Text(leftText).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: left - 6, alignment: .trailing)
                Color.black.frame(width: notch.width + 12)
                Text(rightText).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: right - 6, alignment: .leading)
            }
            .foregroundStyle(.white)
            .frame(height: l.compact.height)
            .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .onHover(perform: onHover)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.compactText.isEmpty ? "Agenda" : model.compactText)
        } else {
            HStack(spacing: 6) {
                if model.capturing {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                } else {
                    Image("Logo").resizable().scaledToFit().frame(width: 15, height: 15).accessibilityHidden(true)
                }
                Text(model.compactText.isEmpty ? "No upcoming meetings" : model.compactText).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(width: NotchGeometry.capsuleSize.width, height: NotchGeometry.capsuleSize.height)
            .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture(perform: onToggle)
            .onHover(perform: onHover)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.compactText.isEmpty ? "Agenda" : model.compactText)
        }
    }

    var leftText: String {
        let parts = model.compactText.components(separatedBy: " • ")
        return (model.capturing ? "● " : "") + (parts.first ?? "")
    }
    var rightText: String {
        let parts = model.compactText.components(separatedBy: " • ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " • ") : ""
    }
}

extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}
