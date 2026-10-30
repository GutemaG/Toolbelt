import AppKit
import Darwin
import IOKit
import IOKit.ps
import ToolbeltKit

/// System: CPU, memory, chip temperature, fans, battery, and the apps using
/// the most energy. Reads only while the tool is on screen, or every two
/// seconds for the CPU number beside its menu bar icon. No permission needed.
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    static let menuBarKey = "system.menuBarCPU"

    private(set) var reading = SystemReading()
    /// Apps by energy, averaged over the last few readings.
    private(set) var apps: [AppUse] = []
    /// Reads the CPU even with no window open, for the menu bar text.
    @ObservationIgnored var menuBar = false { didSet { update() } }

    @ObservationIgnored private let sensors = SystemSensors()
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Windows showing the System tool. A panel that is ordered out stays in
    /// memory, so visibility is checked on every reading, not on disappear.
    @ObservationIgnored private var windows: [WeakWindow] = []
    /// A popover is not visible yet when it asks to be watched.
    @ObservationIgnored private var watchedAt = Date.distantPast

    /// The CPU load for the menu bar, padded so the icon does not shift.
    var menuBarText: String? {
        guard menuBar, let cpu = reading.cpu else { return nil }
        let text = SystemRules.percentText(cpu)
        return String(repeating: "\u{2007}", count: max(4 - text.count, 0)) + text
    }

    /// A window started showing the System tool: read now, then keep reading
    /// while it stays visible.
    func watch(_ window: NSWindow?) {
        guard let window else { return }
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(WeakWindow(window: window))
        watchedAt = .now
        // Restart so the list fills at once instead of after the menu bar's slow pace.
        loop?.cancel()
        loop = nil
        update()
    }

    private var isShown: Bool {
        Date.now.timeIntervalSince(watchedAt) < 1.5 || windows.contains { $0.window?.isVisible == true }
    }

    private func update() {
        let wanted = menuBar || isShown
        if wanted, loop == nil {
            loop = Task { [weak self] in await self?.run() }
        } else if !wanted {
            loop?.cancel()
            loop = nil
        }
    }

    private func run() async {
        var primed = false
        while !Task.isCancelled {
            let detailed = isShown
            guard detailed || menuBar else { break }
            let next = await sensors.read(processes: detailed)
            guard !Task.isCancelled else { break }
            reading = next
            if let found = next.apps { apps = found }
            StatusItems.shared?.refreshIcons()
            // Energy needs two readings; the second comes quickly so the list fills at once.
            try? await Task.sleep(for: detailed && !primed ? .seconds(1) : .seconds(2))
            primed = primed || detailed
        }
        // A cancelled loop was already replaced; only a loop that ran out clears itself.
        if !Task.isCancelled { loop = nil }
    }

    // MARK: Actions on an app in the list

    func runningApps(at path: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }

    func bringToFront(_ app: AppUse) {
        guard let running = runningApps(at: app.path).first(where: { $0.activationPolicy == .regular }) else {
            openActivityMonitor()
            return
        }
        running.unhide()
        running.activate()
    }

    func quit(_ app: AppUse) {
        runningApps(at: app.path).forEach { $0.terminate() }
    }

    /// Asks first: unsaved work in the app is lost.
    func forceQuit(_ app: AppUse, name: String) {
        let alert = NSAlert()
        alert.messageText = "Force Quit “\(name)”?"
        alert.informativeText = "You lose unsaved changes in this app."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runningApps(at: app.path).forEach { $0.forceTerminate() }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

private struct WeakWindow {
    weak var window: NSWindow?
}

// MARK: Readings

nonisolated struct SystemReading: Sendable {
    /// 0–1 across all cores; nil until there are two readings.
    var cpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var temperature: Double?
    var fans: [Fan] = []
    var battery: Battery?
    /// nil when this reading skipped the processes (menu bar only).
    var apps: [AppUse]?

    struct Fan: Sendable, Identifiable {
        let id: Int
        let rpm: Double
        let maxRPM: Double
    }

    struct Battery: Sendable {
        let percent: Int
        let isCharging: Bool
        let onPower: Bool
    }
}

/// Talks to the kernel, the SMC and the sensor hub, off the main thread.
/// Keeps the previous counters, since CPU and energy are rates.
actor SystemSensors {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcesses: [pid_t: (energy: UInt64, cpuTime: UInt64)] = [:]
    private var lastProcessTime: UInt64?
    private var pathCache: [pid_t: String] = [:]
    private var history: [[AppUse]] = []
    private var smc = SMC()
    private var thermal: AnyObject?

    func read(processes: Bool) -> SystemReading {
        var reading = SystemReading()
        reading.cpu = cpuLoad()
        guard processes else { return reading }
        reading.memoryUsed = memoryUsed()
        reading.temperature = temperature()
        reading.fans = fans()
        reading.battery = battery()
        reading.apps = appUse()
        return reading
    }

    // MARK: CPU and memory

    private func cpuLoad() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks else { return nil }
        return SystemRules.cpuLoad(busyBefore: last.busy, totalBefore: last.total, busyAfter: busy, totalAfter: total)
    }

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return SystemRules.memoryUsed(internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                                      wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
                                      pageSize: UInt64(getpagesize()))
    }

    // MARK: Energy per app

    private func appUse() -> [AppUse] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        let now = mach_absolute_time()
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let elapsed = lastProcessTime.map { Double(now - $0) * ticksToSeconds } ?? 0

        var current: [pid_t: (energy: UInt64, cpuTime: UInt64)] = [:]
        var uses: [ProcessUse] = []
        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            // Other users' processes (root, WindowServer) cannot be read; they are not apps people quit.
            guard ok else { continue }
            let counters = (energy: info.ri_energy_nj, cpuTime: info.ri_user_time + info.ri_system_time)
            current[pid] = counters
            guard elapsed > 0, let before = lastProcesses[pid], let path = path(for: pid) else { continue }
            let watts = Double(counters.energy &- before.energy) / 1e9 / elapsed
            // On Apple silicon the CPU times are in mach ticks.
            let cpu = Double(counters.cpuTime &- before.cpuTime) * ticksToSeconds / elapsed * 100
            uses.append(ProcessUse(path: path, watts: watts, cpu: cpu))
        }
        lastProcesses = current
        lastProcessTime = now
        pathCache = pathCache.filter { current[$0.key] != nil }
        guard elapsed > 0 else { return [] }

        history.append(SystemRules.group(uses))
        if history.count > 3 { history.removeFirst() }
        return Array(SystemRules.average(history).filter { $0.watts > 0 || $0.cpu > 0 }.prefix(20))
    }

    /// The executable of the process responsible for this one, so a web
    /// page's process counts toward Safari and a helper toward its app.
    private func path(for pid: pid_t) -> String? {
        if let cached = pathCache[pid] { return cached }
        let owner = responsibility_get_pid_responsible_for_pid(pid)
        // An app's registered location, since some run from a temporary copy
        // (Chromium browsers run from "….app.bundle" in a temp folder).
        if let bundle = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid)?.bundleURL?.path, bundle.hasSuffix(".app") {
            pathCache[pid] = bundle
            return bundle
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(owner > 0 ? owner : pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        pathCache[pid] = path
        return path
    }

    // MARK: Sensors

    /// The chip's die sensors, through the sensor hub. Unknown chips give nil.
    private func temperature() -> Double? {
        if thermal == nil {
            guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
            thermal = client
        }
        guard let thermal, let services = IOHIDEventSystemClientCopyServices(thermal)?.takeRetainedValue() as? [AnyObject] else { return nil }
        let temperatureEvent: Int64 = 15
        let readings: [(name: String, celsius: Double)] = services.compactMap { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return (name, IOHIDEventGetFloatValue(event, Int32(temperatureEvent << 16)))
        }
        return SystemRules.chipTemperature(readings)
    }

    private func fans() -> [SystemReading.Fan] {
        guard let count = smc.uint8("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            guard let rpm = smc.float("F\(index)Ac") else { return nil }
            return SystemReading.Fan(id: index + 1, rpm: Double(rpm), maxRPM: Double(smc.float("F\(index)Mx") ?? 0))
        }
    }

    private func battery() -> SystemReading.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return SystemReading.Battery(percent: capacity * 100 / maximum,
                                         isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                                         onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

// MARK: SMC

/// Reads keys from the System Management Controller, which knows the fans.
/// Reading needs no permission; changing fan speed would need root.
nonisolated struct SMC {
    private var connection: io_connect_t = 0

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    func uint8(_ key: String) -> UInt8? {
        guard let (type, bytes) = read(key), type == "ui8 ", let first = bytes.first else { return nil }
        return first
    }

    func float(_ key: String) -> Float? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count == 4 else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard connection != 0 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var info = SMCParam()
        info.key = code
        info.command = 9 // key info
        guard call(&info) else { return nil }
        var value = SMCParam()
        value.key = code
        value.info = info.info
        value.command = 5 // read bytes
        guard call(&value) else { return nil }
        let type = withUnsafeBytes(of: info.info.dataType.bigEndian) { String(decoding: $0, as: UTF8.self) }
        let size = min(Int(info.info.dataSize), 32)
        return (type, withUnsafeBytes(of: value.bytes) { Array($0.prefix(size)) })
    }

    private func call(_ param: inout SMCParam) -> Bool {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, 2, &param, MemoryLayout<SMCParam>.stride, &output, &size)
        param = output
        return result == KERN_SUCCESS && output.result == 0
    }
}

/// The SMC driver's 80-byte call layout. The padding matches C's alignment.
nonisolated private struct SMCParam {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct Limit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0, padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    var key: UInt32 = 0
    var version = Version()
    var limit = Limit()
    var info = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

// Exported by IOKit and libSystem but not in the SDK headers. Activity
// Monitor and other system monitors read the same sources.
@_silgen_name("IOHIDEventSystemClientCreate")
nonisolated private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
nonisolated private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
nonisolated private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
nonisolated private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
nonisolated private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
nonisolated private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double
@_silgen_name("responsibility_get_pid_responsible_for_pid")
nonisolated private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t
