import AppKit
import SwiftData
import SwiftUI
import ToolbeltKit

/// One annotation, in the image's pixel coordinates (top-left origin), so it
/// draws the same on screen at any zoom and in the saved file.
enum Mark: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: MarkColor, width: CGFloat)
    case box(CGRect, color: MarkColor, width: CGFloat)
    case highlight(CGRect, color: MarkColor)
    case text(String, at: CGPoint, color: MarkColor, size: CGFloat)
    case redact(CGRect)
}

enum MarkTool: String, CaseIterable, Identifiable {
    case arrow, box, highlight, text, redact

    var id: String { rawValue }
    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .highlight: "Highlight"
        case .text: "Text"
        case .redact: "Redact"
        }
    }
    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .redact: "rectangle.fill"
        }
    }
}

/// The colors people draw with. They are part of the picture, not the UI,
/// so they are fixed colors on purpose.
enum MarkColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, black

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .black: .black
        }
    }
}

/// Draws marks into a GraphicsContext already scaled to image pixels.
enum MarkPainter {
    static func draw(_ marks: [Mark], in context: inout GraphicsContext) {
        for mark in marks {
            switch mark {
            case .arrow(let from, let to, let color, let width):
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(width * 4, 24)
                for side in [-1.0, 1.0] {
                    let a = angle + .pi + side * .pi / 7
                    path.move(to: to)
                    path.addLine(to: CGPoint(x: to.x + cos(a) * head, y: to.y + sin(a) * head))
                }
                context.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .box(let rect, let color, let width):
                context.stroke(Path(roundedRect: rect, cornerRadius: width), with: .color(color.color), lineWidth: width)
            case .highlight(let rect, let color):
                var layer = context
                layer.blendMode = .multiply
                layer.fill(Path(rect), with: .color(color.color.opacity(0.4)))
            case .text(let string, let point, let color, let size):
                context.draw(Text(string).font(.system(size: size, weight: .bold)).foregroundStyle(color.color),
                             at: point, anchor: .topLeading)
            case .redact(let rect):
                context.fill(Path(rect), with: .color(.black))
            }
        }
    }

    /// The image with its marks, at full pixel size.
    @MainActor
    static func render(_ image: CGImage, marks: [Mark]) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let view = Canvas { context, _ in
            context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
            MarkPainter.draw(marks, in: &context)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// Opens Markup windows, one per image.
@MainActor
enum MarkupWindow {
    private static var windows: [NSWindow] = []

    static func open(_ capture: Capture, model: AppModel) {
        guard let source = CGImageSourceCreateWithURL(capture.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let host = NSHostingController(rootView: MarkupView(image: image, url: capture.url, model: model).themed())
        let window = NSWindow(contentViewController: host)
        window.title = "Markup – \(capture.name)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // Retina pixels at half size, fit into most of the screen.
        let visible = (NSScreen.screenWithMouse ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        var size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2 + 52)
        let fit = min(1, visible.width * 0.85 / size.width, visible.height * 0.85 / size.height)
        size = CGSize(width: max(size.width * fit, 640), height: max(size.height * fit, 360))
        window.setContentSize(size)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == id } }
        }
    }
}

struct MarkupView: View {
    let image: CGImage
    let url: URL
    let model: AppModel
    @State private var marks: [Mark] = []
    @State private var draft: Mark?
    @State private var tool: MarkTool = .arrow
    @State private var color: MarkColor = .red
    @State private var weight: CGFloat = 8
    @State private var typing: (point: CGPoint, text: String)?
    @State private var savedURL: URL?
    @FocusState private var textFocused: Bool

    private var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let scale = min(geo.size.width / pixelSize.width, geo.size.height / pixelSize.height)
                let shown = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        context.scaleBy(x: scale, y: scale)
                        context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: pixelSize))
                        MarkPainter.draw(marks + (draft.map { [$0] } ?? []), in: &context)
                    }
                    .frame(width: shown.width, height: shown.height)
                    .contentShape(.rect)
                    .gesture(drawing(scale: scale))
                    if let typing {
                        TextField("Text", text: Binding(get: { self.typing?.text ?? "" }, set: { self.typing?.text = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: weight * 4 * scale, weight: .bold))
                            .foregroundStyle(color.color)
                            .focused($textFocused)
                            .frame(width: max(shown.width - typing.point.x * scale, 80), alignment: .leading)
                            .offset(x: typing.point.x * scale, y: typing.point.y * scale) // grid: ok the text field sits where the person clicked
                            .onSubmit(commitText)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(Space.sm)
            .background(.background.secondary)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: Space.md) {
            Picker("Tool", selection: $tool) {
                ForEach(MarkTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool).help(tool.title)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: Space.xs) {
                ForEach(MarkColor.allCases) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 16, height: 16)
                            .overlay { Circle().stroke(.primary, lineWidth: color == swatch ? 2 : 0).padding(-Space.xs) }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.rawValue.capitalized)
                    .accessibilityLabel(swatch.rawValue.capitalized)
                }
            }
            Picker("Line", selection: $weight) {
                Text("Thin").tag(CGFloat(4))
                Text("Medium").tag(CGFloat(8))
                Text("Thick").tag(CGFloat(14))
            }
            .labelsHidden()
            .fixedSize()
            .help("Line weight and text size")
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward") { _ = marks.popLast() }
                .keyboardShortcut("z")
                .labelStyle(.iconOnly)
                .disabled(marks.isEmpty)
                .help("Undo the last mark (⌘Z)")
            Button("Copy", systemImage: "doc.on.doc") { copy() }
                .keyboardShortcut("c")
                .labelStyle(.iconOnly)
                .help("Copy the marked-up image (⌘C)")
            Button(savedURL == nil ? "Save" : "Saved", systemImage: "square.and.arrow.down") { save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .help("Save as a new file next to the original (⌘S)")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private func drawing(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if typing != nil { commitText() }
                guard tool != .text else { return }
                let a = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                let b = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                switch tool {
                case .arrow: draft = .arrow(from: a, to: b, color: color, width: weight)
                case .box: draft = .box(rect, color: color, width: weight)
                case .highlight: draft = .highlight(rect, color: color)
                case .redact: draft = .redact(rect)
                case .text: break
                }
            }
            .onEnded { value in
                if tool == .text {
                    typing = (CGPoint(x: value.location.x / scale, y: value.location.y / scale), "")
                    textFocused = true
                    return
                }
                // A click without a drag adds nothing.
                if let draft, hypot(value.translation.width, value.translation.height) > 4 { marks.append(draft) }
                draft = nil
                savedURL = nil
            }
    }

    private func commitText() {
        if let typing, !typing.text.trimmingCharacters(in: .whitespaces).isEmpty {
            marks.append(.text(typing.text, at: typing.point, color: color, size: weight * 4))
            savedURL = nil
        }
        typing = nil
    }

    private func copy() {
        commitText()
        guard let result = MarkPainter.render(image, marks: marks) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: result, size: .zero)])
        Toast.show("Copied the marked-up image", symbol: "doc.on.doc")
    }

    /// Writes "<name> (annotated).png" beside the original, which stays untouched.
    private func save() {
        commitText()
        guard let result = MarkPainter.render(image, marks: marks) else { return }
        let base = url.deletingPathExtension().lastPathComponent
        let target = CaptureRules.uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) (annotated).png") {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        model.context.insert(Capture(kind: .screenshot, url: target, width: result.width, height: result.height))
        try? model.context.save()
        savedURL = target
        Toast.show("Saved \(target.lastPathComponent)", symbol: "checkmark.circle")
    }
}
