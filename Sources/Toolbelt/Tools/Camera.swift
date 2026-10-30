import AVFoundation
import AppKit
import SwiftUI
import ToolbeltKit

/// Camera: a live preview inside Toolbelt, to check how you look before a
/// call without opening an app. The camera runs only while a window showing
/// it is on screen, so the green light goes out when the window closes.
@Observable
final class Camera {
    static let shared = Camera()
    static let mirrorKey = "camera.mirror"
    private static let deviceKey = "camera.device"

    enum State: Equatable {
        case off, starting, running, denied, noCamera, failed
    }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private(set) var state: State = .off
    private(set) var devices: [Device] = []
    private(set) var deviceID: String?
    /// Test and snapshot runs never turn the camera on; they show a placeholder.
    let isSimulated = Store.isOverridden

    @ObservationIgnored let session = CameraSession()
    /// Views showing the preview right now.
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        // A camera plugged in or an iPhone coming close shows up in the list at once.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            })
        }
    }

    static var mirrors: Bool { UserDefaults.standard.object(forKey: mirrorKey) as? Bool ?? true }

    static func toggleMirror() {
        UserDefaults.standard.set(!mirrors, forKey: mirrorKey)
    }

    var deviceName: String? { devices.first { $0.id == deviceID }?.name }

    /// A view showing the preview came on screen or left it.
    func show(_ viewer: UUID, _ visible: Bool) {
        if visible { viewers.insert(viewer) } else { viewers.remove(viewer) }
        viewers.isEmpty ? stop() : start()
    }

    func select(_ id: String) {
        guard id != deviceID else { return }
        UserDefaults.standard.set(id, forKey: Self.deviceKey)
        deviceID = id
        restart()
    }

    func retry() {
        state = .off
        if !viewers.isEmpty { start() }
    }

    func refreshDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                     mediaType: .video, position: .unspecified).devices
        devices = found.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        deviceID = CameraRules.pick(saved: UserDefaults.standard.string(forKey: Self.deviceKey),
                                    preferred: AVCaptureDevice.systemPreferredCamera?.uniqueID,
                                    available: devices.map(\.id))
    }

    /// Saves what the preview shows, mirrored the same way, to the screenshot folder.
    func takePhoto() {
        guard state == .running else { return NSSound.beep() }
        let mirrored = Self.mirrors
        Task {
            guard let image = await session.photo() else { return NSSound.beep() }
            CaptureController.shared.save(mirrored ? Self.flipped(image) ?? image : image, kind: "Photo")
        }
    }

    // MARK: Running

    private func start() {
        guard !isSimulated, state != .starting, state != .running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            state = .starting
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                state = granted ? .off : .denied
                if granted, !viewers.isEmpty { start() }
            }
            return
        default:
            state = .denied
            return
        }
        refreshDevices()
        guard let id = deviceID else {
            state = .noCamera
            return
        }
        state = .starting
        Task {
            let started = await session.start(deviceID: id)
            // Closed or switched while starting: that call already moved on.
            guard state == .starting, id == deviceID else { return }
            state = started ? .running : .failed
        }
    }

    private func stop() {
        guard state == .starting || state == .running else { return }
        session.stop()
        state = .off
    }

    private func restart() {
        guard state == .starting || state == .running else { return }
        state = .off
        start()
    }

    private func devicesChanged() {
        let current = deviceID
        refreshDevices()
        if state == .noCamera || (deviceID != current && state != .off) { retry() }
    }

    static func flipped(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// The capture session, used on its own queue: starting a camera blocks.
nonisolated final class CameraSession: NSObject, @unchecked Sendable, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photos = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.birhanu.toolbelt.camera")
    private var input: AVCaptureDeviceInput?
    private var photoDone: ((CGImage?) -> Void)?

    /// Shows the camera with this id, starting the session if needed. False when it cannot be opened.
    func start(deviceID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.startNow(deviceID)) }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func photo() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.session.isRunning, self.photoDone == nil, self.session.outputs.contains(self.photos) else {
                    return continuation.resume(returning: nil)
                }
                self.photoDone = { continuation.resume(returning: $0) }
                self.photos.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.cgImageRepresentation() : nil
        queue.async {
            self.photoDone?(image)
            self.photoDone = nil
        }
    }

    private func startNow(_ id: String) -> Bool {
        session.beginConfiguration()
        if input?.device.uniqueID != id {
            if let input { session.removeInput(input) }
            input = nil
            if let device = AVCaptureDevice(uniqueID: id), let new = try? AVCaptureDeviceInput(device: device), session.canAddInput(new) {
                session.addInput(new)
                input = new
            }
        }
        if !session.outputs.contains(photos), session.canAddOutput(photos) { session.addOutput(photos) }
        session.commitConfiguration()
        guard input != nil else { return false }
        if !session.isRunning { session.startRunning() }
        return session.isRunning
    }
}

// MARK: The view

/// The preview, then the camera menu, Mirror and Take Photo.
struct CameraView: View {
    let surface: Surface
    let window: NSWindow?
    @Environment(AppModel.self) private var model
    @AppStorage(Camera.mirrorKey) private var mirror = true
    @State private var viewer = UUID()
    @State private var flash = false
    private var camera: Camera { .shared }

    var body: some View {
        VStack(spacing: Space.md) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.quinary)
                // The shutter flash covers the picture, not chrome, so plain white is right.
                .overlay { if flash { Rectangle().fill(.white) } }
                .clipShape(.rect(cornerRadius: 12))
            controls
        }
        .padding(Space.md)
        .onAppear(perform: camera.refreshDevices)
        .task(id: window) {
            // A closed popover or panel stays in memory, so check that it is on screen.
            while !Task.isCancelled {
                camera.show(viewer, window?.isVisible == true)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onDisappear { camera.show(viewer, false) }
        .onChange(of: model.photoCount) { takePhoto() }
    }

    @ViewBuilder
    private var preview: some View {
        if camera.isSimulated {
            ContentUnavailableView("Camera Preview", systemImage: "person.crop.rectangle",
                                   description: Text("Test runs never turn the camera on."))
        } else {
            switch camera.state {
            case .denied:
                ContentUnavailableView {
                    Label("Camera Access Off", systemImage: "video.slash")
                } description: {
                    Text("Allow Toolbelt under Camera in System Settings to see the preview.")
                } actions: {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            case .noCamera:
                ContentUnavailableView("No Camera", systemImage: "web.camera",
                                       description: Text("Connect a camera, or bring your iPhone close to use it as a Continuity Camera."))
            case .failed:
                ContentUnavailableView {
                    Label("Unable to Start the Camera", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("It may be busy or disconnected.")
                } actions: {
                    Button("Try Again") { camera.retry() }
                }
            case .off, .starting, .running:
                CameraLayer(session: camera.session.session, mirror: mirror)
                    .overlay { if camera.state == .starting { ProgressView().controlSize(.small) } }
                    .accessibilityLabel("Camera preview")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Space.sm) {
            if camera.devices.count > 1 {
                Picker("Camera", selection: Binding(get: { camera.deviceID ?? "" }, set: camera.select)) {
                    ForEach(camera.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Choose the camera")
            } else if let name = camera.deviceName {
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle(isOn: $mirror) {
                Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .toggleStyle(.button)
            .help("Flip the preview like a mirror (M)")
            Button("Take Photo", systemImage: "camera", action: takePhoto)
                .buttonStyle(.borderedProminent)
                .disabled(camera.state != .running)
                .help("Save a photo to your screenshot folder (↩)")
        }
        .controlSize(surface == .popover ? .small : .regular)
    }

    private func takePhoto() {
        guard camera.state == .running else { return }
        camera.takePhoto()
        flash = true
        withAnimation(.easeOut(duration: 0.3)) { flash = false }
    }
}

/// The live picture. Mirroring flips the layer, so it works on every camera.
private struct CameraLayer: NSViewRepresentable {
    let session: AVCaptureSession
    let mirror: Bool

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirror = mirror
    }

    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer
        var mirror = true { didSet { needsLayout = true } }

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.setAffineTransform(.identity)
            preview.frame = bounds
            preview.setAffineTransform(CGAffineTransform(scaleX: mirror ? -1 : 1, y: 1))
            CATransaction.commit()
        }
    }
}
