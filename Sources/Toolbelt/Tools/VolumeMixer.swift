import AppKit
import AudioToolbox
import CoreAudio
import ToolbeltKit

/// Volume Mixer: the output volume, and a volume for each app playing sound.
///
/// macOS has no per-app volume. An app turned down or muted gets a Core Audio
/// process tap that silences it, and its sound is played again through the
/// current output at the chosen volume. Apps at full volume are not touched.
/// A tap lives only while its app plays, so the audio hardware can sleep.
@Observable
final class VolumeMixer {
    static let shared = VolumeMixer()
    private static let levelsKey = "mixer.levels"
    private static let mutedKey = "mixer.muted"

    struct App: Identifiable, Equatable {
        /// The bundle id, or the path for an app without one.
        let id: String
        let name: String
        let path: String?
        /// Core Audio process objects of the app and its helpers.
        var processes: [AudioObjectID]
        var isPlaying: Bool
    }

    private(set) var apps: [App] = []
    private(set) var levels: [String: Double]
    private(set) var muted: Set<String>
    private(set) var outputName = ""
    private(set) var outputVolume: Double?
    private(set) var outputMuted = false
    private(set) var permission = AudioCapture.status
    /// The keyboard row: 0 is the output, then the apps in order.
    var selection = 0
    /// Test and snapshot runs read but never change any sound.
    let isSimulated = Store.isOverridden

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    /// Apps being played through Toolbelt right now.
    var tapCount: Int { taps.count }
    @ObservationIgnored private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var outputUID: String?

    init() {
        let defaults = Store.isOverridden ? nil : UserDefaults.standard
        levels = defaults?.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        muted = Set(defaults?.stringArray(forKey: Self.mutedKey) ?? [])
    }

    func level(_ app: App) -> Double { levels[app.id] ?? 1 }
    func isMuted(_ app: App) -> Bool { muted.contains(app.id) }

    // MARK: Changing volumes

    func setLevel(_ level: Double, for app: App) {
        levels[app.id] = level >= 0.995 ? nil : level
        if level > 0 { muted.remove(app.id) }
        changed()
    }

    func toggleMute(_ app: App) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        changed()
    }

    func reset(_ app: App) {
        levels[app.id] = nil
        muted.remove(app.id)
        changed()
    }

    func setOutputVolume(_ level: Double) {
        outputVolume = level
        guard !isSimulated else { return }
        AudioOutput.setVolume(level)
        if outputMuted, level > 0 { toggleOutputMute() }
    }

    func toggleOutputMute() {
        outputMuted.toggle()
        if !isSimulated { AudioOutput.setMuted(outputMuted) }
    }

    /// ↑ and ↓ move between rows, ← and → change the volume, Return mutes.
    func step(_ offset: Int, in shown: [App]) {
        selection = min(max(selection + offset, 0), shown.count)
    }

    func nudge(_ step: Double, in shown: [App]) {
        if selection == 0 {
            if let volume = outputVolume { setOutputVolume(MixerRules.nudge(volume, by: step)) }
        } else if shown.indices.contains(selection - 1) {
            let app = shown[selection - 1]
            setLevel(MixerRules.nudge(isMuted(app) ? 0 : level(app), by: step), for: app)
        }
    }

    func toggleSelected(in shown: [App]) {
        if selection == 0 { toggleOutputMute() } else if shown.indices.contains(selection - 1) { toggleMute(shown[selection - 1]) }
    }

    private func changed() {
        if !isSimulated {
            UserDefaults.standard.set(levels, forKey: Self.levelsKey)
            UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
        }
        let wantsTaps = apps.contains { MixerRules.needsTap(level: level($0), muted: isMuted($0)) }
        if wantsTaps, permission == .unknown, !isSimulated {
            Task {
                permission = await AudioCapture.request()
                refresh()
            }
            return
        }
        listen(!levels.isEmpty || !muted.isEmpty)
        sync()
    }

    // MARK: Reading

    /// Reads the output and the apps playing sound, then fits the taps to them.
    func refresh() {
        let output = AudioOutput.current
        outputName = output.flatMap(AudioOutput.name) ?? "No Output"
        outputVolume = AudioOutput.volume
        outputMuted = AudioOutput.isMuted
        permission = AudioCapture.status
        let found = AudioProcesses.apps(excluding: ProcessInfo.processInfo.processIdentifier)
        apps = Snapshot.requested && found.isEmpty ? Self.samples : found
        if outputUID != output.flatMap(AudioOutput.uid) {
            // A new output: every tap plays through the old one, so start them again.
            outputUID = output.flatMap(AudioOutput.uid)
            taps.values.forEach { $0.invalidate() }
            taps = [:]
        }
        sync()
    }

    /// Starts Volume Mixer at launch when an app has a saved volume.
    func resume() {
        guard !levels.isEmpty || !muted.isEmpty else { return }
        listen(true)
        refresh()
    }

    /// Turned off in Settings, or Toolbelt is quitting: every app plays as before.
    func stopAll() {
        listen(false)
        taps.values.forEach { $0.invalidate() }
        taps = [:]
    }

    /// Makes the taps match the volumes: one per app that is turned down and playing.
    private func sync() {
        guard !isSimulated else { return }
        var wanted: [String: (processes: [AudioObjectID], gain: Float)] = [:]
        if permission == .allowed, let outputUID {
            for app in apps where app.isPlaying && MixerRules.needsTap(level: level(app), muted: isMuted(app)) {
                wanted[app.id] = (app.processes, MixerRules.gain(level: level(app), muted: isMuted(app)))
            }
            for (id, want) in wanted {
                if let tap = taps[id], tap.processes == want.processes {
                    tap.gain.pointee = want.gain
                } else {
                    taps[id]?.invalidate()
                    taps[id] = AppTap(processes: want.processes, outputUID: outputUID, gain: want.gain)
                }
            }
        }
        for id in taps.keys where wanted[id] == nil {
            taps[id]?.invalidate()
            taps[id] = nil
        }
    }

    // MARK: Watching Core Audio

    /// While an app has a saved volume, follow apps starting and stopping
    /// sound, and output changes, so its volume applies with the window closed.
    private func listen(_ on: Bool) {
        guard !isSimulated, on != listening else {
            if on { watchProcesses() }
            return
        }
        listening = on
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if on {
                AudioObjectAddPropertyListenerBlock(system, &address, .main, systemListener)
            } else {
                AudioObjectRemovePropertyListenerBlock(system, &address, .main, systemListener)
            }
        }
        if on { watchProcesses() } else { unwatchProcesses() }
    }

    @ObservationIgnored private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated {
            self?.watchProcesses()
            self?.refresh()
        }
    }

    /// Each process says when it starts or stops playing.
    private func watchProcesses() {
        let current = Set(AudioProcesses.objects())
        var address = Self.runningAddress
        for (id, block) in listeners where !current.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            listeners[id] = nil
        }
        for id in current where listeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr { listeners[id] = block }
        }
    }

    private func unwatchProcesses() {
        var address = Self.runningAddress
        for (id, block) in listeners { AudioObjectRemovePropertyListenerBlock(id, &address, .main, block) }
        listeners = [:]
    }

    private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Shown in snapshots when nothing is playing, so the page has rows.
    private static let samples: [App] = [
        App(id: "com.apple.Music", name: "Music", path: "/System/Applications/Music.app", processes: [], isPlaying: true),
        App(id: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app", processes: [], isPlaying: true),
        App(id: "com.apple.FaceTime", name: "FaceTime", path: "/System/Applications/FaceTime.app", processes: [], isPlaying: false),
    ]

    /// Sample volumes for snapshots, kept in memory.
    func useSampleLevels() {
        levels = ["com.apple.Safari": 0.45]
        muted = ["com.apple.FaceTime"]
    }
}

// MARK: Apps playing sound

nonisolated enum AudioProcesses {
    static func objects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Apps with sound clients, helpers counted toward their app. An app shows
    /// while any of its processes is playing, or once it has played.
    @MainActor
    static func apps(excluding own: pid_t) -> [VolumeMixer.App] {
        var byApp: [String: VolumeMixer.App] = [:]
        var order: [String] = []
        for object in objects() {
            guard let pid: pid_t = value(object, kAudioProcessPropertyPID), pid > 0, pid != own else { continue }
            let owner = responsibility_get_pid_responsible_for_pid(pid)
            guard owner != own,
                  let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid) ?? NSRunningApplication(processIdentifier: pid),
                  app.bundleURL?.pathExtension == "app",
                  let key = app.bundleIdentifier ?? app.bundleURL?.path else { continue }
            let playing = (value(object, kAudioProcessPropertyIsRunningOutput) as UInt32?) == 1
            if var entry = byApp[key] {
                entry.processes.append(object)
                entry.isPlaying = entry.isPlaying || playing
                byApp[key] = entry
            } else {
                byApp[key] = VolumeMixer.App(id: key, name: app.localizedName ?? key, path: app.bundleURL?.path,
                                             processes: [object], isPlaying: playing)
                order.append(key)
            }
        }
        // Playing apps first, then by name, so rows do not jump around while one plays.
        return order.compactMap { byApp[$0] }
            .filter { $0.isPlaying || VolumeMixer.shared.levels[$0.id] != nil || VolumeMixer.shared.muted.contains($0.id) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}

// MARK: One app's tap

/// Silences an app's processes and plays them through the output at `gain`.
nonisolated final class AppTap: @unchecked Sendable {
    let processes: [AudioObjectID]
    /// Read on the audio thread every few milliseconds; a Float write is atomic.
    let gain: UnsafeMutablePointer<Float>
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init?(processes: [AudioObjectID], outputUID: String, gain level: Float) {
        self.processes = processes
        gain = .allocate(capacity: 1)
        gain.initialize(to: level)
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Toolbelt Volume Mixer"
        description.isPrivate = true
        // Silent only while Toolbelt plays it back: if this fails, the app is heard as before.
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            invalidate()
            return nil
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Toolbelt Volume Mixer",
            kAudioAggregateDeviceUIDKey: "com.birhanu.toolbelt.mixer." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            invalidate()
            return nil
        }
        let gain = Gain(pointer: gain)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
            AppTap.render(input, output, gain.pointer.pointee)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            invalidate()
            return nil
        }
    }

    func invalidate() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        gain.deallocate()
    }

    private struct Gain: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<Float>
    }

    /// Copies the tapped sound, interleaved Float32, to every output channel it
    /// has, scaled. Runs on the real-time audio thread: no allocation, no locks.
    private static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, _ gain: Float) {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let targets = UnsafeMutableAudioBufferListPointer(output)
        guard let source = sources.first, let samples = source.mData?.assumingMemoryBound(to: Float.self) else {
            for target in targets { if let data = target.mData { memset(data, 0, Int(target.mDataByteSize)) } }
            return
        }
        let inChannels = max(Int(source.mNumberChannels), 1)
        let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
        var firstChannel = 0
        for target in targets {
            guard let data = target.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = max(Int(target.mNumberChannels), 1)
            let outFrames = Int(target.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            for frame in 0..<outFrames {
                for channel in 0..<outChannels {
                    let from = firstChannel + channel
                    data[frame * outChannels + channel] = frame < frames && from < inChannels
                        ? samples[frame * inChannels + from] * gain : 0
                }
            }
            firstChannel += outChannels
        }
    }
}

// MARK: Permission

/// "System Audio Recording Only" in Privacy & Security, which taps need.
/// macOS has no public check, so this asks TCC directly, like Apple's sample.
nonisolated enum AudioCapture {
    enum Status { case allowed, denied, unknown }

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static var status: Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let preflight = symbol("TCCAccessPreflight", as: Preflight.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request() async -> Status {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let request = symbol("TCCAccessRequest", as: Request.self) else { return status }
        let granted = await withCheckedContinuation { continuation in
            request(service, nil) { continuation.resume(returning: $0) }
        }
        return granted ? .allowed : .denied
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
nonisolated private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t
