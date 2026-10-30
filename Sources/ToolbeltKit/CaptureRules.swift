import CoreGraphics
import Foundation

/// File names and geometry for screenshots and recordings.
public enum CaptureRules {
    /// "Toolbelt Screenshot 2026-10-30 at 18.04.12.png", like macOS names its own.
    public static func fileName(kind: String, date: Date, ext: String, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d.%02d.%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "Toolbelt \(kind) \(day) at \(time).\(ext)"
    }

    /// A name that does not exist yet in `folder`: adds " 2", " 3"… before the extension.
    public static func uniqueURL(in folder: URL, name: String, exists: (URL) -> Bool) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// A selection drawn on a screen (points, bottom-left origin, as AppKit
    /// gives it) turned into pixels of that screen's image (top-left origin).
    public static func pixelRect(selection: CGRect, screenHeight: CGFloat, scale: CGFloat) -> CGRect {
        let flipped = CGRect(x: selection.minX, y: screenHeight - selection.maxY,
                             width: selection.width, height: selection.height)
        return CGRect(x: (flipped.minX * scale).rounded(), y: (flipped.minY * scale).rounded(),
                      width: (flipped.width * scale).rounded(), height: (flipped.height * scale).rounded())
    }

    /// The same selection in points with a top-left origin, which
    /// ScreenCaptureKit's sourceRect expects.
    public static func topLeftRect(selection: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: selection.minX, y: screenHeight - selection.maxY, width: selection.width, height: selection.height)
    }

    /// The rect between two drag points, kept inside `bounds`.
    public static func dragRect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .intersection(bounds)
    }

    /// "1:05", "12:00", "1:02:03" for the recording timer.
    public static func elapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
