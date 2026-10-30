import AppKit
import IOKit
import IOKit.hid
import ToolbeltKit

/// Reads the motion sensor in Apple silicon MacBooks (M2 and later, M1 Pro
/// and Max): a Bosch IMU behind the undocumented AppleSPUHIDDevice, about 800
/// readings a second. Each reading goes through a KnockDetector on the
/// sensor's own thread; only finished knocks reach the main thread.
/// How to wake and read it comes from mactap (MIT, github.com/jaskirat1616/mactap-app).
nonisolated final class KnockSensor: @unchecked Sendable {
    /// What the meter shows: movement now and its peak since the last look, in g.
    struct Reading: Sendable {
        var level = 0.0
        var peak = 0.0
        var threshold = 0.05
        var rate = 0.0
    }

    private static let usagePage: UInt32 = 0xFF00
    private static let accelerometer: UInt32 = 3
    private static let reportLength = 22
    private static let dataOffset = 6
    private static let wakeInterval: Int32 = 8000  // µs: pokes a parked sensor
    private static let runInterval: Int32 = 1250   // µs: 800 readings a second

    private let onEvent: @Sendable (KnockDetector.Event) -> Void
    private let lock = NSLock()
    private var detector: KnockDetector
    private var reading = Reading()
    private var device: IOHIDDevice?
    private var runLoop: CFRunLoop?
    private var keepAlive: DispatchSourceTimer?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let start = CACurrentMediaTime()
    private var lastReading = 0.0
    private var countThisSecond = 0
    private var secondStarted = 0.0
    private var typing = false
    private var typingCheckedAt = 0.0

    init(sensitivity: Double, onEvent: @escaping @Sendable (KnockDetector.Event) -> Void) {
        detector = KnockDetector(sensitivity: sensitivity)
        self.onEvent = onEvent
    }

    deinit { buffer.deallocate() }

    /// True when this Mac has the sensor at all.
    static var isPresent: Bool {
        guard let service = findAccelerometer() else { return false }
        IOObjectRelease(service)
        return true
    }

    var sensitivity: Double {
        get { lock.withLock { detector.sensitivity } }
        set { lock.withLock { detector.sensitivity = newValue } }
    }

    /// The meter's values; the peak starts again after each look.
    func take() -> Reading {
        lock.withLock {
            let now = reading
            reading.peak = reading.level
            return now
        }
    }

    /// Opens the sensor and starts reading. False when it cannot be opened.
    func begin() -> Bool {
        guard device == nil else { return true }
        Self.wake()
        guard let service = Self.findAccelerometer() else { return false }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, Self.runInterval as CFNumber)
        self.device = device
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            Unmanaged<KnockSensor>.fromOpaque(context).takeUnretainedValue().handle(report, length)
        }, Unmanaged.passUnretained(self).toOpaque())

        let thread = Thread { [weak self] in
            guard let self, let device = self.device else { return }
            let loop = CFRunLoopGetCurrent()!
            self.lock.withLock { self.runLoop = loop }
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopRun()
        }
        thread.name = "Toolbelt Knock sensor"
        thread.qualityOfService = .userInteractive
        thread.start()

        // macOS parks a still sensor after a while: reports stop or slow to
        // about 100 a second, which misses knocks. Wake it when that happens.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (silent, rate) = self.lock.withLock { (CACurrentMediaTime() - self.start - self.lastReading, self.reading.rate) }
            if silent > 0.25 || rate < 450 { Self.wake() }
        }
        timer.resume()
        keepAlive = timer
        return true
    }

    func end() {
        keepAlive?.cancel()
        keepAlive = nil
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let loop = lock.withLock({ runLoop }) { CFRunLoopStop(loop) }
        lock.withLock {
            runLoop = nil
            reading = Reading(threshold: reading.threshold)
        }
    }

    // MARK: On the sensor thread

    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard length == Self.reportLength else { return }
        func axis(_ index: Int) -> Double {
            let offset = Self.dataOffset + index * 4
            let bits = UInt32(report[offset]) | UInt32(report[offset + 1]) << 8 | UInt32(report[offset + 2]) << 16 | UInt32(report[offset + 3]) << 24
            return Double(Int32(bitPattern: bits)) / 65536
        }
        let time = CACurrentMediaTime() - start
        // Reading the last key press costs a call; every 20 ms is plenty.
        if time - typingCheckedAt > 0.02 {
            typingCheckedAt = time
            typing = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.45
        }
        let event: KnockDetector.Event? = lock.withLock {
            let event = detector.add(time: time, x: axis(0), y: axis(1), z: axis(2), typing: typing)
            reading.level = detector.level
            reading.peak = max(reading.peak, detector.level)
            reading.threshold = detector.threshold
            lastReading = time
            countThisSecond += 1
            if time - secondStarted >= 1 {
                reading.rate = Double(countThisSecond) / (time - secondStarted)
                countThisSecond = 0
                secondStarted = time
            }
            return event
        }
        if let event { onEvent(event) }
    }

    // MARK: Finding and waking the sensor

    private static func findAccelerometer() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if number(service, "PrimaryUsagePage") == usagePage, number(service, "PrimaryUsage") == accelerometer { return service }
            IOObjectRelease(service)
        }
        return nil
    }

    /// Asks the sensor driver to report, and at full speed. Setting this on
    /// the HID device alone does nothing; it has to go to the driver.
    private static func wake() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, wakeInterval as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, runInterval as CFNumber)
            IOObjectRelease(service)
        }
    }

    private static func number(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint32Value
    }
}
