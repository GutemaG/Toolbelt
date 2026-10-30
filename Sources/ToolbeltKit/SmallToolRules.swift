import CoreGraphics
import Foundation

/// A color as 0–255 sRGB channels, and the text formats people copy.
public struct RGB: Equatable, Sendable {
    public var r: Int, g: Int, b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r; self.g = g; self.b = b
    }

    /// From 0–1 components, rounded.
    public init(red: Double, green: Double, blue: Double) {
        func channel(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: channel(red), g: channel(green), b: channel(blue))
    }

    /// "#1A2B3C" or "1a2b3c".
    public init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(r: (value >> 16) & 0xFF, g: (value >> 8) & 0xFF, b: value & 0xFF)
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    public var rgb: String { "rgb(\(r), \(g), \(b))" }

    public var hsl: String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
        let l = (maxV + minV) / 2
        var h = 0.0, s = 0.0
        let d = maxV - minV
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case rf: h = (gf - bf) / d + (gf < bf ? 6 : 0)
            case gf: h = (bf - rf) / d + 2
            default: h = (rf - gf) / d + 4
            }
            h *= 60
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    public func text(_ format: ColorTextFormat) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgb
        case .hsl: hsl
        }
    }
}

public enum ColorTextFormat: String, CaseIterable, Sendable {
    case hex, rgb, hsl
}

/// Where window snapping puts the front window.
public enum WindowPosition: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, center

    /// The window's new frame inside the screen's visible frame. Both use
    /// AppKit coordinates (origin at the bottom left). Center keeps the size.
    public func frame(in screen: CGRect, current: CGRect) -> CGRect {
        let w = screen.width, h = screen.height, x = screen.minX, y = screen.minY
        func rect(_ fx: CGFloat, _ fw: CGFloat) -> CGRect {
            CGRect(x: (x + w * fx).rounded(), y: y, width: (w * fw).rounded(), height: h)
        }
        switch self {
        case .leftHalf: return rect(0, 0.5)
        case .rightHalf: return rect(0.5, 0.5)
        case .topHalf: return CGRect(x: x, y: (y + h / 2).rounded(), width: w, height: (h / 2).rounded())
        case .bottomHalf: return CGRect(x: x, y: y, width: w, height: (h / 2).rounded())
        case .leftThird: return rect(0, 1.0 / 3)
        case .centerThird: return rect(1.0 / 3, 1.0 / 3)
        case .rightThird: return rect(2.0 / 3, 1.0 / 3)
        case .leftTwoThirds: return rect(0, 2.0 / 3)
        case .rightTwoThirds: return rect(1.0 / 3, 2.0 / 3)
        case .maximize: return screen
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            return CGRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }

    /// AppKit's bottom-left frame turned into the top-left frame the
    /// Accessibility API uses, given the height of the main (menu bar) screen.
    public static func axFrame(_ frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// Removes tracking parameters from links people copy.
public enum LinkCleaner {
    static let exact: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid",
        "yclid", "twclid", "ttclid", "_hsenc", "_hsmi", "mkt_tok", "si", "ref_src", "ref_url", "spm",
    ]
    static let prefixes = ["utm_", "pk_", "vero_", "oly_"]

    /// The link without tracking parameters, or nil when there was nothing to remove.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let items = parts.queryItems, !items.isEmpty,
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            // "si" only means tracking on YouTube and Spotify share links.
            if name == "si" { return !(parts.host ?? "").contains("youtu") && !(parts.host ?? "").contains("spotify") }
            return !exact.contains(name) && !prefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string
    }
}
