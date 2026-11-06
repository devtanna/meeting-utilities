import CoreGraphics
import Foundation

/// Auto-scroll math for Talktrack (§16.2): offset advances by speed × elapsed monotonic time, so the visible speed
/// is identical at 60 Hz, 120 Hz or with dropped frames.
public enum TeleprompterScroll {
    public static let speedRange: ClosedRange<Double> = 8...80
    public static let fontRange: ClosedRange<Double> = 16...48
    public static let defaultFontSize: Double = 24

    public static func advance(offset: CGFloat, speed: Double, elapsed: Double, maxOffset: CGFloat) -> (offset: CGFloat, reachedEnd: Bool) {
        let s = min(max(speed, speedRange.lowerBound), speedRange.upperBound)
        let next = offset + CGFloat(s * max(0, elapsed))
        return next >= maxOffset ? (maxOffset, true) : (next, false)
    }
}
