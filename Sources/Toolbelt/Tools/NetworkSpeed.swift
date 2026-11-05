import AppKit
import Charts
import Darwin
import Network
import SwiftUI
import ToolbeltKit

/// Network Speed: how fast this Mac is sending and receiving right now, read
/// from the system's byte counters, and a speed test on request. It reads only
/// while the tool is on screen, or once a second for the menu bar when that's
/// on. Nothing goes over the network except the test you start. Test and
/// snapshot runs show samples and never start one.
@Observable
final class NetworkSpeed {
    static let shared = NetworkSpeed()
    static let menuBarKey = "networkSpeed.menuBar"
    private static let unitKey = "networkSpeed.unit"
    /// One reading a second, for a minute.
    static let historyLength = 60

    /// Bytes per second. nil until there are two readings.
    private(set) var down: Double?
    private(set) var up: Double?
    private(set) var history: [NetworkSample] = []
    private(set) var connection = NetworkConnection.unknown
    var speedTest = SpeedTestState.idle
    var unit: SpeedUnit = SpeedUnit(rawValue: Store.isOverridden ? "" : UserDefaults.standard.string(forKey: unitKey) ?? "") ?? .bytes {
        didSet {
            if !Store.isOverridden { UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey) }
            StatusItems.shared?.refreshIcons()
        }
    }
    /// Reads even with no window open, for the menu bar text.
    @ObservationIgnored var menuBar = false { didSet { update() } }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var last: (counters: NetworkCounters, date: Date)?
    @ObservationIgnored private var path: NWPathMonitor?
    @ObservationIgnored private var shown = ShownWindows()
    @ObservationIgnored private var testRun: ShellHandle?

    var menuBarText: String? {
        guard menuBar, let down, let up else { return nil }
        return NetworkRules.menuBarText(down: down, up: up, unit: unit)
    }

    /// Test and snapshot runs show samples. The self-test turns this off to try the real loop.
    @ObservationIgnored var usesSamples = Store.isOverridden
    var isReading: Bool { loop != nil }

    /// A window started showing the tool: keep reading while it stays visible.
    func watch(_ window: NSWindow?) {
        if usesSamples {
            fillWithSamples()
            return
        }
        shown.watch(window)
        update()
    }

    private func update() {
        guard !usesSamples else { return }
        let wanted = menuBar || shown.isShown
        if wanted, loop == nil {
            loop = Task { [weak self] in await self?.run() }
        } else if !wanted {
            loop?.cancel()
            finished()
        }
        StatusItems.shared?.refreshIcons()
    }

    private func run() async {
        last = nil
        history = []
        down = nil
        up = nil
        watchConnection()
        while !Task.isCancelled, menuBar || shown.isShown {
            record(NetworkCounters.read(), at: .now)
            StatusItems.shared?.refreshIcons()
            try? await Task.sleep(for: .seconds(1))
        }
        // A cancelled loop was already cleared by whoever cancelled it.
        if !Task.isCancelled { finished() }
    }

    private func finished() {
        loop = nil
        path?.cancel()
        path = nil
    }

    /// One reading of the counters: the speed since the last one.
    func record(_ counters: NetworkCounters, at date: Date) {
        defer { last = (counters, date) }
        guard let last else { return }
        let seconds = date.timeIntervalSince(last.date)
        // A counter that went back holds the last speed for this one reading.
        let sample = NetworkSample(down: NetworkRules.rate(from: last.counters.received, to: counters.received, seconds: seconds) ?? down ?? 0,
                                   up: NetworkRules.rate(from: last.counters.sent, to: counters.sent, seconds: seconds) ?? up ?? 0)
        down = sample.down
        up = sample.up
        history.append(sample)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func watchConnection() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { update in
            let found = NetworkConnection(update)
            Task { @MainActor in NetworkSpeed.shared.connection = found }
        }
        monitor.start(queue: .global(qos: .utility))
        path = monitor
    }

    // MARK: Speed test

    var isTesting: Bool {
        if case .running = speedTest { return true }
        return false
    }

    /// Return: start the test, or stop the one running.
    func toggleTest() {
        isTesting ? stopTest() : startTest()
    }

    func startTest() {
        guard !isTesting else { return }
        guard !Store.isOverridden else {
            speedTest = .finished(Self.sampleResult, at: .now)
            return
        }
        speedTest = .running(since: .now)
        let handle = ShellHandle()
        testRun = handle
        Task {
            let result = await Shell.run("/usr/bin/networkQuality", ["-c"], timeout: Self.testTimeout, handle: handle)
            // Stopped by hand: the state has already moved on.
            guard testRun === handle else { return }
            testRun = nil
            if let found = result.flatMap({ NetworkRules.parseSpeedTest($0.output) }) {
                speedTest = .finished(found, at: .now)
            } else {
                speedTest = .failed
            }
        }
    }

    func stopTest() {
        testRun?.stop()
        testRun = nil
        speedTest = .idle
    }

    /// A slow connection took 47 seconds here; this only catches one that hangs.
    private static let testTimeout: TimeInterval = 180

    // MARK: Samples

    static let sampleResult = SpeedTestResult(downloadBitsPerSecond: 312_000_000, uploadBitsPerSecond: 41_500_000, latencyMilliseconds: 14, loadedLatencyMilliseconds: 86)

    private func fillWithSamples() {
        connection = .wifi
        history = (0..<Self.historyLength).map { index in
            let x = Double(index)
            return NetworkSample(down: 6_500_000 + 3_500_000 * sin(x / 5) + 2_500_000 * sin(x / 1.7),
                                 up: 500_000 + 300_000 * sin(x / 9) + 150_000 * sin(x / 2.3))
        }
        down = history.last?.down
        up = history.last?.up
    }
}

nonisolated struct NetworkSample: Sendable {
    let down: Double
    let up: Double
}

enum SpeedTestState {
    case idle
    case running(since: Date)
    case finished(SpeedTestResult, at: Date)
    case failed
}

enum NetworkConnection: Sendable {
    case unknown, wifi, ethernet, cellular, other, offline

    nonisolated init(_ path: NWPath) {
        if path.status != .satisfied { self = .offline }
        else if path.usesInterfaceType(.wifi) { self = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { self = .ethernet }
        else if path.usesInterfaceType(.cellular) { self = .cellular }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .unknown: "Checking…"
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: "Cellular"
        case .other: "Connected"
        case .offline: "No Connection"
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "network"
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        case .offline: "wifi.slash"
        }
    }
}

/// The bytes through this Mac's real interfaces, for telling speeds apart. Not
/// a lifetime total: though declared 64-bit, macOS 27 gives apps download
/// counts wrapped at 4 GB and rounded to 1 KB, as getifaddrs does too.
nonisolated struct NetworkCounters: Sendable {
    var received: UInt64 = 0
    var sent: UInt64 = 0

    static func read() -> NetworkCounters {
        var counters = NetworkCounters()
        var request: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&request, UInt32(request.count), nil, &size, nil, 0) == 0, size > 0 else { return counters }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, UInt32(request.count), &buffer, &size, nil, 0) == 0 else { return counters }
        buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil,
                       NetworkRules.countsTraffic(interface: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) {
                        counters.received += info.ifm_data.ifi_ibytes
                        counters.sent += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return counters
    }
}

// MARK: The tool

struct NetworkSpeedView: View {
    let window: NSWindow?
    @Environment(AppModel.self) private var model
    private var speed: NetworkSpeed { .shared }

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Label(speed.connection.title, systemImage: speed.connection.symbol)
                Spacer(minLength: 0)
                Text("Last Minute")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: Space.sm) {
                SpeedCard(title: "Download", symbol: "arrow.down", tint: .blue, rate: speed.down, values: speed.history.map(\.down))
                SpeedCard(title: "Upload", symbol: "arrow.up", tint: .pink, rate: speed.up, values: speed.history.map(\.up))
            }
            SpeedTestCard()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { speed.watch(window) }
        .onChange(of: window) { speed.watch(window) }
        .onChange(of: model.openCount) { speed.watch(window) }
    }
}

/// One direction: the speed now, its last minute, and the peak. Download and
/// upload each get their own chart and scale, since upload is often far smaller.
private struct SpeedCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let rate: Double?
    let values: [Double]
    @State private var hovered: Int?
    private var unit: SpeedUnit { NetworkSpeed.shared.unit }
    /// The newest reading sits at the right edge, whatever has been read so far.
    private var firstSlot: Int { NetworkSpeed.historyLength - values.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(rate.map { NetworkRules.speed($0, unit: unit) } ?? "–")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            chart
                .frame(maxHeight: .infinity)
            Text(caption)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(rate.map { NetworkRules.speed($0, unit: unit) } ?? "Reading")
    }

    private var caption: String {
        if let hovered, values.indices.contains(hovered) {
            let ago = values.count - 1 - hovered
            return (ago == 0 ? "Now" : "\(ago) s ago") + ": " + NetworkRules.speed(values[hovered], unit: unit)
        }
        return "Peak " + NetworkRules.speed(values.max() ?? 0, unit: unit)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Time", firstSlot + index), y: .value("Speed", value))
                    .foregroundStyle(tint.opacity(0.18))
                LineMark(x: .value("Time", firstSlot + index), y: .value("Speed", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let hovered, values.indices.contains(hovered) {
                RuleMark(x: .value("Time", firstSlot + hovered))
                    .foregroundStyle(.secondary)
                PointMark(x: .value("Time", firstSlot + hovered), y: .value("Speed", values[hovered]))
                    .foregroundStyle(tint)
                    .symbolSize(32)
            }
        }
        .chartXScale(domain: 0...(NetworkSpeed.historyLength - 1))
        // A quiet line shouldn't look busy: the scale never goes below 10 KB/s.
        .chartYScale(domain: 0...max(values.max() ?? 0, 10_000))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            Color.clear
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = proxy.value(atX: location.x, as: Int.self).map { $0 - firstSlot }
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }
}

private struct SpeedTestCard: View {
    private var speed: NetworkSpeed { .shared }
    private var tint: Color { Tool.networkSpeed.tint }

    var body: some View {
        Group {
            switch speed.speedTest {
            case .idle:
                row(title: "Speed Test", detail: "Runs Apple’s network test when you click. Takes about a minute and can use a few hundred MB.") {
                    Button("Test Speed") { speed.startTest() }
                        .buttonStyle(TintedActionStyle(tint: tint))
                        .help("Start the speed test (↩)")
                }
            case .running(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    row(title: "Testing…", detail: "\(Int(context.date.timeIntervalSince(since))) s. It usually takes about a minute.", busy: true) {
                        Button("Stop") { speed.stopTest() }
                            .buttonStyle(QuickActionStyle())
                            .help("Stop the speed test (↩)")
                    }
                }
            case .finished(let result, let date):
                finished(result, at: date)
            case .failed:
                row(title: "The Test Didn’t Finish", detail: "Check your connection and try again.") {
                    Button("Try Again") { speed.startTest() }
                        .buttonStyle(TintedActionStyle(tint: tint))
                        .help("Start the speed test (↩)")
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }

    private func row<Action: View>(title: String, detail: String, busy: Bool = false, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: Space.md) {
            if busy {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
        }
    }

    private func finished(_ result: SpeedTestResult, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                stat("Download", NetworkRules.speed(result.downloadBitsPerSecond / 8, unit: .bits))
                stat("Upload", NetworkRules.speed(result.uploadBitsPerSecond / 8, unit: .bits))
                if let idle = result.latencyMilliseconds { stat("Latency", NetworkRules.latency(idle)) }
                if let busy = result.loadedLatencyMilliseconds { stat("Under Load", NetworkRules.latency(busy)) }
            }
            HStack(spacing: Space.md) {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Test Again") { speed.startTest() }
                    .buttonStyle(QuickActionStyle())
                    .help("Run the speed test again (↩)")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Settings > Network Speed.
struct NetworkSpeedOptions: View {
    @AppStorage(NetworkSpeed.menuBarKey) private var menuBar = false

    var body: some View {
        @Bindable var speed = NetworkSpeed.shared
        Section {
            Toggle(isOn: $menuBar) {
                Text("Show live speeds in the menu bar")
                Text("Upload and download as numbers, read once a second.")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: menuBar) { ToolPrefs.shared.onChange?() }
            Picker("Show speeds in", selection: $speed.unit) {
                ForEach(SpeedUnit.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Options")
        } footer: {
            Text("Live speeds come from counters on this Mac, cover Wi-Fi, Ethernet and cellular, and use no data. Only Test Speed goes online: it runs macOS’s networkQuality against Apple’s servers, which can use a few hundred MB, and always reports in Mbps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
