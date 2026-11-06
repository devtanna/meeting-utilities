import CoreGraphics
import Foundation

/// Pure geometry for notch mode, from injected screen metrics (§5.3, A7). Tested with synthetic values because
/// notched hardware is an open verification item.
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect                 // full screen frame (AppKit coordinates, origin bottom-left)
    public var visibleFrame: CGRect          // excludes menu bar and Dock
    public var safeAreaTop: CGFloat          // NSScreen.safeAreaInsets.top (non-zero on notched displays)
    public var auxiliaryTopLeft: CGRect?     // area left of the camera housing
    public var auxiliaryTopRight: CGRect?    // area right of the camera housing

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft; self.auxiliaryTopRight = auxiliaryTopRight
    }

    public var hasNotch: Bool { safeAreaTop > 0 && auxiliaryTopLeft != nil && auxiliaryTopRight != nil }
}

public struct NotchLayout: Sendable, Equatable {
    public var compact: CGRect
    public var expanded: CGRect
    public var notchRect: CGRect?            // the camera housing gap within `compact`, if any
    public var isNotched: Bool
}

public enum NotchGeometry {
    public static let sideWidth: CGFloat = 120
    public static let capsuleSize = CGSize(width: 340, height: 28)
    public static let expandedWidth: CGFloat = 430

    public static func layout(_ m: ScreenMetrics, expandedHeight: CGFloat) -> NotchLayout {
        if m.hasNotch, let left = m.auxiliaryTopLeft, let right = m.auxiliaryTopRight {
            let notchMinX = left.maxX, notchMaxX = right.minX
            let barHeight = m.safeAreaTop
            // Stay within the auxiliary areas next to the housing so menus (left) and status items/clock (right) remain clear.
            let lw = min(sideWidth, left.width / 3), rw = min(sideWidth, right.width / 3)
            let compact = CGRect(x: notchMinX - lw, y: m.frame.maxY - barHeight, width: (notchMaxX - notchMinX) + lw + rw, height: barHeight)
            let notch = CGRect(x: notchMinX, y: compact.minY, width: notchMaxX - notchMinX, height: barHeight)
            return NotchLayout(compact: compact, expanded: expandedRect(m, centerX: notch.midX, top: m.frame.maxY - barHeight, height: expandedHeight),
                               notchRect: notch, isNotched: true)
        }
        // No notch: a top-centre capsule inside the visible frame, below the menu bar.
        let top = m.visibleFrame.maxY - 4
        let compact = CGRect(x: m.visibleFrame.midX - capsuleSize.width / 2, y: top - capsuleSize.height, width: capsuleSize.width, height: capsuleSize.height)
        return NotchLayout(compact: compact, expanded: expandedRect(m, centerX: m.visibleFrame.midX, top: compact.minY - 4, height: expandedHeight),
                           notchRect: nil, isNotched: false)
    }

    static func expandedRect(_ m: ScreenMetrics, centerX: CGFloat, top: CGFloat, height: CGFloat) -> CGRect {
        let maxHeight = top - m.visibleFrame.minY - 8
        let h = min(height, maxHeight)
        var x = centerX - expandedWidth / 2
        x = max(m.visibleFrame.minX + 8, min(x, m.visibleFrame.maxX - expandedWidth - 8))
        return CGRect(x: x, y: top - h, width: expandedWidth, height: h)
    }
}
