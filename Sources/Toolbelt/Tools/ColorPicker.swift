import AppKit
import ToolbeltKit

/// Colors: the system color sampler (a magnifier over the screen, no Screen
/// Recording permission needed), then copy the color as text.
@MainActor
final class ColorPicker {
    static var shared: ColorPicker!
    private let model: AppModel
    private var sampling = false

    static let formatKey = "colors.format"
    static let recentKey = "colors.recent"
    static var format: ColorTextFormat { ColorTextFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .hex }

    init(model: AppModel) {
        self.model = model
        model.recentColors = Store.isOverridden ? [] : (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
    }

    func pick() {
        guard !sampling else { return }
        sampling = true
        PanelController.shared.hide()
        StatusItems.shared?.closePopovers()
        NSApp.activate()
        NSColorSampler().show { [weak self] color in
            Task { @MainActor in
                guard let self else { return }
                self.sampling = false
                guard let color, let srgb = color.usingColorSpace(.sRGB) else { return }
                let rgb = RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
                self.remember(rgb)
                self.copy(rgb, as: Self.format)
            }
        }
    }

    func copy(_ rgb: RGB, as format: ColorTextFormat) {
        let text = rgb.text(format)
        if !Store.isOverridden {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Toast.show("Copied \(text)", symbol: "eyedropper")
    }

    /// Keeps the last 12 colors, newest first, without repeats.
    func remember(_ rgb: RGB) {
        var recent = model.recentColors.filter { $0 != rgb.hex }
        recent.insert(rgb.hex, at: 0)
        model.recentColors = Array(recent.prefix(12))
        if !Store.isOverridden { UserDefaults.standard.set(model.recentColors, forKey: Self.recentKey) }
    }

    func forget(_ hex: String) {
        model.recentColors.removeAll { $0 == hex }
        if !Store.isOverridden { UserDefaults.standard.set(model.recentColors, forKey: Self.recentKey) }
    }
}
