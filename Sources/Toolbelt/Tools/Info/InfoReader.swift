import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import ToolbeltKit

/// Reads each Info tab off the main thread. Nothing here needs a permission,
/// except the Wi-Fi name (Location) and the public IP (one web request).
nonisolated enum InfoReader {
    struct Options: Sendable {
        var locationAllowed: Bool
        /// The self-test turns this off so it never contacts the internet.
        var lookUpPublicIP: Bool
    }

    @concurrent
    static func read(_ tab: InfoTab, options: Options) async -> [InfoSection] {
        switch tab {
        case .battery: await battery()
        case .storage: await storage()
        case .hardware: await hardware()
        case .network: await network(options)
        case .developer: await developer()
        }
    }

    // MARK: Battery

    static func battery() async -> [InfoSection] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              properties["BatteryInstalled"] as? Bool ?? true else { return [] }
        let details = properties["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            let value = properties[key] ?? details[key]
            if let number = value as? NSNumber { return Int(truncatingIfNeeded: number.int64Value) }
            return nil
        }
        func bool(_ key: String) -> Bool { (properties[key] as? Bool) ?? false }

        let profile = await Shell.profile(["SPPowerDataType"])
        let power = profile["SPPowerDataType"] as? [[String: Any]] ?? []
        let health = power.lazy.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }.first

        let charge = int("CurrentCapacity") ?? 0
        let plugged = bool("ExternalConnected"), charging = bool("IsCharging"), full = bool("FullyCharged")
        let state = full ? "Fully charged" : charging ? "Charging" : plugged ? "Not charging (on power)" : "On battery"
        var now = [InfoRow(label: "Charge", value: "\(charge)%", fraction: Double(charge) / 100),
                   InfoRow(label: "Status", value: state)]
        if charging, let left = InfoRules.clock(minutes: int("AvgTimeToFull") ?? 0) {
            now.append(InfoRow(label: "Time to full", value: left))
        } else if !plugged {
            now.append(InfoRow(label: "Time remaining", value: InfoRules.clock(minutes: int("AvgTimeToEmpty") ?? 0) ?? "Calculating…"))
        }
        if let volts = int("Voltage"), let amps = int("Amperage"), amps != 0 {
            let watts = Double(volts) * Double(amps) / 1_000_000
            now.append(InfoRow(label: watts > 0 ? "Charging at" : "Using", value: String(format: "%.1f W", abs(watts))))
        }
        now.append(InfoRow(label: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off"))

        let design = int("DesignCapacity") ?? 0
        let fullCharge = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        let maximum = (health?["sppower_battery_health_maximum_capacity"] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            ?? InfoRules.maximumCapacity(fullCharge: fullCharge, design: design)
        var healthRows = [InfoRow(label: "Condition", value: InfoRules.batteryCondition(health?["sppower_battery_health"] as? String, maximumCapacity: maximum))]
        if let maximum { healthRows.append(InfoRow(label: "Maximum capacity", value: "\(maximum)%", fraction: Double(maximum) / 100)) }
        if let cycles = int("CycleCount") {
            healthRows.append(InfoRow(label: "Cycle count", value: "\(cycles)"))
        }
        if fullCharge > 0 { healthRows.append(InfoRow(label: "Full charge capacity", value: "\(fullCharge.formatted()) mAh")) }
        if design > 0 { healthRows.append(InfoRow(label: "Design capacity", value: "\(design.formatted()) mAh")) }
        if let current = int("AppleRawCurrentCapacity") { healthRows.append(InfoRow(label: "Charge now", value: "\(current.formatted()) mAh")) }

        var detail: [InfoRow] = []
        if let temperature = int("Temperature") { detail.append(InfoRow(label: "Temperature", value: String(format: "%.1f °C", Double(temperature) / 100))) }
        if let volts = int("Voltage") { detail.append(InfoRow(label: "Voltage", value: String(format: "%.2f V", Double(volts) / 1000))) }
        if let amps = int("Amperage") { detail.append(InfoRow(label: "Current", value: "\(amps.formatted()) mA")) }
        if let cells = details["CellVoltage"] as? [NSNumber], !cells.isEmpty {
            detail.append(InfoRow(label: "Cell voltages", value: cells.map { String(format: "%.3f", $0.doubleValue / 1000) }.joined(separator: " · ") + " V"))
        }
        if let name = properties["DeviceName"] as? String { detail.append(InfoRow(label: "Battery chip", value: name)) }
        if let serial = (properties["Serial"] ?? details["Serial"]) as? String { detail.append(InfoRow(label: "Serial number", value: serial, secret: true)) }

        var sections = [InfoSection(title: "Now", rows: now),
                        InfoSection(title: "Health", rows: healthRows,
                                    note: "Condition and maximum capacity match System Settings > Battery."),
                        InfoSection(title: "Details", rows: detail)]
        if plugged, let adapter = properties["AdapterDetails"] as? [String: Any] {
            var rows: [InfoRow] = []
            if let name = adapter["Name"] as? String { rows.append(InfoRow(label: "Adapter", value: name)) }
            if let watts = adapter["Watts"] as? Int { rows.append(InfoRow(label: "Rated power", value: "\(watts) W")) }
            if let millivolts = adapter["AdapterVoltage"] as? Int, let milliamps = adapter["Current"] as? Int {
                rows.append(InfoRow(label: "Supplying", value: String(format: "%.0f V · %.2f A", Double(millivolts) / 1000, Double(milliamps) / 1000)))
            }
            if let serial = adapter["SerialString"] as? String, !serial.isEmpty { rows.append(InfoRow(label: "Serial number", value: serial, secret: true)) }
            if !rows.isEmpty { sections.append(InfoSection(title: "Power Adapter", rows: rows)) }
        }
        return sections
    }

    // MARK: Storage

    static func storage() async -> [InfoSection] {
        var sections: [InfoSection] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
                                      .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let root = await Shell.plist("/usr/sbin/diskutil", ["info", "-plist", "/"])
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let isRoot = values.volumeIsRootFileSystem ?? false
            // Network shares (OrbStack, a NAS) and simulator disk images are not this Mac's storage.
            if url.path.hasPrefix("/Library/Developer") || !(values.volumeIsLocal ?? true) { continue }
            let free = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? Int64(values.volumeAvailableCapacity ?? 0)
            let used = Int64(total) - free
            var rows = [InfoRow(label: "Used", value: "\(InfoRules.bytes(used)) of \(InfoRules.bytes(Int64(total)))",
                                fraction: Double(used) / Double(total)),
                        InfoRow(label: "Available", value: InfoRules.bytes(free),
                                help: "Includes space macOS frees on its own, like Finder shows"),
                        InfoRow(label: "File system", value: values.volumeLocalizedFormatDescription ?? "Unknown"),
                        InfoRow(label: "Location", value: (values.volumeIsInternal ?? false) ? "Internal" : (values.volumeIsRemovable ?? false) ? "Removable" : "External")]
            if isRoot {
                if let device = root["DeviceIdentifier"] as? String { rows.append(InfoRow(label: "Device", value: device)) }
                if let fileVault = root["FileVault"] as? Bool { rows.append(InfoRow(label: "FileVault", value: fileVault ? "On" : "Off")) }
            } else {
                rows.append(InfoRow(label: "Mounted at", value: url.path))
            }
            sections.append(InfoSection(title: values.volumeName ?? url.lastPathComponent, rows: rows))
        }

        // The physical disks.
        let profile = await Shell.profile(["SPNVMeDataType"])
        for controller in profile["SPNVMeDataType"] as? [[String: Any]] ?? [] {
            for disk in controller["_items"] as? [[String: Any]] ?? [] {
                var rows: [InfoRow] = []
                if let model = disk["device_model"] as? String { rows.append(InfoRow(label: "Model", value: model)) }
                if let size = disk["size"] as? String { rows.append(InfoRow(label: "Capacity", value: size)) }
                let solid = root["SolidState"] as? Bool ?? true
                let bus = root["BusProtocol"] as? String
                rows.append(InfoRow(label: "Type", value: (solid ? "SSD" : "Hard disk") + (bus.map { " · \($0)" } ?? " · NVMe")))
                if let smart = disk["smart_status"] as? String {
                    rows.append(InfoRow(label: "Health", value: smart == "Verified" ? "Verified (S.M.A.R.T.)" : smart, help: "The disk's own self-check"))
                }
                if let trim = disk["spnvme_trim_support"] as? String { rows.append(InfoRow(label: "TRIM", value: trim)) }
                if let firmware = disk["device_revision"] as? String { rows.append(InfoRow(label: "Firmware", value: firmware)) }
                if let map = disk["partition_map_type"] as? String {
                    rows.append(InfoRow(label: "Partition map", value: map.contains("guid") ? "GUID" : map.contains("master") ? "Master Boot Record" : map))
                }
                if let serial = disk["device_serial"] as? String { rows.append(InfoRow(label: "Serial number", value: serial, secret: true)) }
                sections.append(InfoSection(title: "Disk \(disk["bsd_name"] as? String ?? "")".trimmingCharacters(in: .whitespaces), rows: rows))
            }
        }

        // Partitions of each physical disk, and the volumes in the startup container.
        let list = await Shell.plist("/usr/sbin/diskutil", ["list", "-plist", "physical"])
        for disk in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            guard let id = disk["DeviceIdentifier"] as? String, !partitions.isEmpty else { continue }
            let rows = partitions.map { part in
                InfoRow(label: "\(part["DeviceIdentifier"] as? String ?? "?") · \(partitionName(part["Content"] as? String ?? ""))",
                        value: InfoRules.bytes((part["Size"] as? NSNumber)?.int64Value ?? 0))
            }
            sections.append(InfoSection(title: "Partitions on \(id)", rows: rows))
        }
        if let container = root["ParentWholeDisk"] as? String {
            let apfs = await Shell.plist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
            for item in apfs["Containers"] as? [[String: Any]] ?? [] {
                let rows = (item["Volumes"] as? [[String: Any]] ?? []).map { volume in
                    let roles = (volume["Roles"] as? [String] ?? []).joined(separator: ", ")
                    let name = volume["Name"] as? String ?? "?"
                    return InfoRow(label: roles.isEmpty || roles == name ? name : "\(name) (\(roles))",
                                   value: InfoRules.bytes((volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0))
                }
                if !rows.isEmpty {
                    sections.append(InfoSection(title: "APFS Volumes on \(container)", rows: rows,
                                                note: "Volumes share the container's space; each shows what it uses."))
                }
            }
        }
        return sections
    }

    private static func partitionName(_ content: String) -> String {
        switch content {
        case "Apple_APFS": "APFS Container"
        case "Apple_APFS_ISC": "APFS (System Firmware)"
        case "Apple_APFS_Recovery": "APFS (Recovery)"
        case "EFI": "EFI"
        case "Apple_HFS": "Mac OS Extended"
        case "Microsoft Basic Data": "ExFAT or FAT"
        default: content.isEmpty ? "Free" : content
        }
    }

    // MARK: Hardware

    static func hardware() async -> [InfoSection] {
        let profile = await Shell.profile(["SPHardwareDataType", "SPDisplaysDataType"])
        let overview = (profile["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        let graphics = profile["SPDisplaysDataType"] as? [[String: Any]] ?? []

        var mac = [InfoRow(label: "Model", value: productName() ?? overview["machine_name"] as? String ?? "Mac")]
        if let id = overview["machine_model"] as? String ?? sysctlString("hw.model") { mac.append(InfoRow(label: "Model identifier", value: id)) }
        if let number = overview["model_number"] as? String { mac.append(InfoRow(label: "Model number", value: number)) }
        if let serial = overview["serial_number"] as? String { mac.append(InfoRow(label: "Serial number", value: serial, secret: true)) }
        if let firmware = overview["boot_rom_version"] as? String { mac.append(InfoRow(label: "Firmware", value: firmware)) }

        var chip = [InfoRow(label: "Chip", value: overview["chip_type"] as? String ?? sysctlString("machdep.cpu.brand_string") ?? "Unknown")]
        var name = utsname()
        uname(&name)
        let machine = withUnsafeBytes(of: name.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        chip.append(InfoRow(label: "Architecture", value: machine == "arm64" ? "arm64 (Apple silicon)" : "\(machine) (Intel)"))
        let total = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        let levels = (0..<(sysctlInt("hw.nperflevels") ?? 0)).compactMap { level -> String? in
            guard let count = sysctlInt("hw.perflevel\(level).physicalcpu"), let kind = sysctlString("hw.perflevel\(level).name") else { return nil }
            return "\(count) \(kind)"
        }
        chip.append(InfoRow(label: "CPU cores", value: levels.isEmpty ? "\(total)" : "\(total) (\(levels.joined(separator: ", ")))"))
        if let gpu = graphics.first(where: { ($0["sppci_device_type"] as? String) == "spdisplays_gpu" }) ?? graphics.first {
            chip.append(InfoRow(label: "GPU", value: gpu["sppci_model"] as? String ?? "Unknown"))
            if let cores = gpu["sppci_cores"] as? String { chip.append(InfoRow(label: "GPU cores", value: cores)) }
            if let metal = gpu["spdisplays_mtlgpufamilysupport"] as? String {
                chip.append(InfoRow(label: "Metal", value: metal.replacingOccurrences(of: "spdisplays_metal", with: "Metal ")))
            }
        }
        chip.append(InfoRow(label: "Memory", value: overview["physical_memory"] as? String ?? InfoRules.bytes(Int64(ProcessInfo.processInfo.physicalMemory))))
        if machine == "arm64" {
            let rosetta = FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            chip.append(InfoRow(label: "Rosetta 2", value: rosetta ? "Installed" : "Not installed", help: "Runs apps built for Intel Macs"))
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        var system = [InfoRow(label: "Name", value: InfoRules.macOSName(major: version.majorVersion)),
                      InfoRow(label: "Version", value: "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")),
                      InfoRow(label: "Build", value: sysctlString("kern.osversion") ?? "?")]
        let kernel = withUnsafeBytes(of: name.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        system.append(InfoRow(label: "Kernel", value: "Darwin \(kernel)"))
        if let boot = bootTime() {
            system.append(InfoRow(label: "Uptime", value: InfoRules.duration(Date.now.timeIntervalSince(boot))))
            system.append(InfoRow(label: "Last boot", value: boot.formatted(date: .abbreviated, time: .shortened)))
        }
        system.append(InfoRow(label: "Computer name", value: Host.current().localizedName ?? "?"))
        system.append(InfoRow(label: "User", value: NSUserName()))

        var displays: [InfoRow] = []
        for gpu in graphics {
            for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                let name = display["_name"] as? String ?? "Display"
                let looksLike = (display["_spdisplays_resolution"] as? String ?? "").replacingOccurrences(of: ".00Hz", with: " Hz")
                let pixels = display["_spdisplays_pixels"] as? String
                let builtIn = (display["spdisplays_connection_type"] as? String) == "spdisplays_internal"
                displays.append(InfoRow(label: name + (builtIn ? " (built-in)" : ""),
                                        value: looksLike.isEmpty ? (pixels ?? "?") : looksLike,
                                        help: pixels.map { "\($0) pixels" }))
            }
        }
        var sections = [InfoSection(title: "Mac", rows: mac), InfoSection(title: "Chip", rows: chip),
                        InfoSection(title: "macOS", rows: system)]
        if !displays.isEmpty { sections.append(InfoSection(title: "Displays", rows: displays)) }
        return sections
    }

    /// "MacBook Pro (16-inch, M5 Pro)", from the device tree.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(key, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    // MARK: Network

    static func network(_ options: Options) async -> [InfoSection] {
        var sections: [InfoSection] = []
        let addresses = interfaceAddresses()
        let store = SCDynamicStoreCreate(nil, "Toolbelt" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] } ?? [:]
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) as? [String: Any] } ?? [:]
        let primary = global["PrimaryInterface"] as? String
        let names = interfaceNames()

        if let wifi = CWWiFiClient.shared().interface() {
            var rows: [InfoRow] = []
            let on = wifi.powerOn()
            let rssi = wifi.rssiValue()
            let connected = on && rssi != 0
            rows.append(InfoRow(label: "Status", value: !on ? "Off" : connected ? "Connected" : "On, not connected"))
            if connected {
                if let name = wifi.ssid() {
                    rows.append(InfoRow(label: "Network", value: name))
                } else {
                    rows.append(InfoRow(label: "Network", value: options.locationAllowed ? "Hidden" : "Allow Location to show…",
                                        help: "macOS shows Wi-Fi names only to apps allowed to use Location Services",
                                        action: options.locationAllowed ? nil : .allowLocation))
                }
                rows.append(InfoRow(label: "Signal", value: "\(rssi) dBm (\(InfoRules.signal(rssi: rssi)))",
                                    fraction: min(max(Double(rssi + 90) / 60, 0), 1)))
                rows.append(InfoRow(label: "Noise", value: "\(wifi.noiseMeasurement()) dBm"))
                if let channel = wifi.wlanChannel() {
                    let band = [CWChannelBand.band2GHz: "2.4 GHz", .band5GHz: "5 GHz", .band6GHz: "6 GHz"][channel.channelBand]
                    let width = [CWChannelWidth.width20MHz: "20 MHz", .width40MHz: "40 MHz", .width80MHz: "80 MHz", .width160MHz: "160 MHz"][channel.channelWidth]
                    rows.append(InfoRow(label: "Channel", value: "\(channel.channelNumber)" + ([band, width].compactMap { $0 }.isEmpty ? "" : " (\([band, width].compactMap { $0 }.joined(separator: ", ")))")))
                }
                let modes: [CWPHYMode: String] = [.mode11a: "802.11a", .mode11b: "802.11b", .mode11g: "802.11g", .mode11n: "Wi-Fi 4 (802.11n)",
                                                  .mode11ac: "Wi-Fi 5 (802.11ac)", .mode11ax: "Wi-Fi 6 (802.11ax)", .mode11be: "Wi-Fi 7 (802.11be)"]
                if let mode = modes[wifi.activePHYMode()] { rows.append(InfoRow(label: "Standard", value: mode)) }
                rows.append(InfoRow(label: "Link speed", value: "\(Int(wifi.transmitRate())) Mbps"))
                rows.append(InfoRow(label: "Security", value: security(wifi.security())))
            }
            if let name = wifi.interfaceName {
                rows.append(InfoRow(label: "Interface", value: name))
                if let mac = addresses[name]?.mac { rows.append(InfoRow(label: "MAC address", value: mac, secret: true)) }
            }
            sections.append(InfoSection(title: "Wi-Fi", rows: rows))
        }

        var internet: [InfoRow] = []
        if options.lookUpPublicIP {
            internet.append(InfoRow(label: "Public IP", value: await publicIP() ?? "Not reachable", secret: true))
        }
        if let primary {
            internet.append(InfoRow(label: "Connected through", value: "\(names[primary] ?? primary) (\(primary))"))
            if let ipv4 = addresses[primary]?.ipv4.first { internet.append(InfoRow(label: "Local IP", value: ipv4)) }
            if let ipv6 = addresses[primary]?.ipv6.first { internet.append(InfoRow(label: "IPv6", value: ipv6)) }
        } else {
            internet.append(InfoRow(label: "Status", value: "Not connected"))
        }
        if let router = global["Router"] as? String { internet.append(InfoRow(label: "Router", value: router)) }
        if let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty {
            internet.append(InfoRow(label: "DNS servers", value: servers.joined(separator: ", ")))
        }
        if let domains = dns["SearchDomains"] as? [String], !domains.isEmpty {
            internet.append(InfoRow(label: "Search domains", value: domains.joined(separator: ", ")))
        }
        let tunnels = addresses.filter { $0.key.hasPrefix("utun") && !$0.value.ipv4.isEmpty }
        internet.append(InfoRow(label: "VPN", value: tunnels.isEmpty ? "Not connected" : "Connected (\(tunnels.keys.sorted().joined(separator: ", ")))"))
        sections.append(InfoSection(title: "Internet", rows: internet,
                                    note: options.lookUpPublicIP ? "The public IP comes from api.ipify.org each time this tab opens." : nil))

        let others = addresses.keys.sorted().filter { name in
            name != primary && !name.hasPrefix("utun") && !name.hasPrefix("lo") && !(addresses[name]?.ipv4.isEmpty ?? true)
        }
        if !others.isEmpty {
            sections.append(InfoSection(title: "Other Connections", rows: others.map { name in
                let kind = names[name] ?? (name.hasPrefix("bridge") ? "Virtual network" : nil)
                return InfoRow(label: kind.map { "\($0) (\(name))" } ?? name, value: addresses[name]?.ipv4.joined(separator: ", ") ?? "")
            }))
        }
        return sections
    }

    private struct Addresses {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var mac: String?
    }

    /// Every interface that is up, with its addresses.
    private static func interfaceAddresses() -> [String: Addresses] {
        var result: [String: Addresses] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, (Int32(entry.ifa_flags) & IFF_UP) != 0 else { continue }
            let name = String(cString: entry.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if address.pointee.sa_family == AF_INET {
                    result[name, default: Addresses()].ipv4.append(text)
                } else if !text.hasPrefix("fe80") {
                    result[name, default: Addresses()].ipv6.append(text)
                }
            case AF_LINK:
                let mac = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
                    guard link.pointee.sdl_alen == 6 else { return nil }
                    return withUnsafeBytes(of: link.pointee.sdl_data) { bytes in
                        let start = Int(link.pointee.sdl_nlen)
                        guard bytes.count >= start + 6 else { return nil }
                        return bytes[start..<(start + 6)].map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
                if let mac { result[name, default: Addresses()].mac = mac }
            default:
                break
            }
        }
        return result
    }

    /// "Wi-Fi", "Ethernet", "Thunderbolt Bridge" by BSD name.
    private static func interfaceNames() -> [String: String] {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var names: [String: String] = [:]
        for interface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? { names[bsd] = name }
        }
        return names
    }

    private static func security(_ value: CWSecurity) -> String {
        switch value {
        case .none: "None"
        case .WEP, .dynamicWEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA Personal"
        case .wpa2Personal, .personal: "WPA2 Personal"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Transition: "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise: "WPA2 Enterprise"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .OWE, .oweTransition: "Enhanced Open"
        default: "Unknown"
        }
    }

    private static func publicIP() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count < 64 ? text : nil
    }

    // MARK: Developer

    static func developer() async -> [InfoSection] {
        let environment = await toolEnvironment()
        let path = (environment["PATH"] ?? "").split(separator: ":").map { String($0).replacingOccurrences(of: "~", with: NSHomeDirectory()) }
        let hasDeveloperTools = await Shell.run("/usr/bin/xcode-select", ["-p"])?.status == 0
        let hasJava = await Shell.run("/usr/libexec/java_home", [])?.status == 0

        // Each tool's version, all at once.
        let found = await withTaskGroup(of: (DevTool, String, String)?.self) { group in
            for tool in DevTool.all {
                guard let executable = path.lazy.map({ "\($0)/\(tool.executable)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
                // Apple's stand-ins in /usr/bin open an install dialog when the real tool is missing.
                if executable == "/usr/bin/\(tool.executable)", DevTool.appleStubs.contains(tool.executable) {
                    if tool.executable == "java" ? !hasJava : !hasDeveloperTools { continue }
                }
                group.addTask {
                    guard let result = await Shell.run(executable, tool.arguments, environment: environment, timeout: 8),
                          result.status == 0, let version = InfoRules.version(in: result.output, after: tool.marker) else { return nil }
                    return (tool, version, executable)
                }
            }
            var all: [(DevTool, String, String)] = []
            for await item in group { if let item { all.append(item) } }
            return all
        }

        var sections: [InfoSection] = []
        for group in DevTool.Group.allCases {
            let rows = DevTool.all.filter { $0.group == group }.compactMap { tool in
                found.first { $0.0 == tool }.map { InfoRow(label: tool.name, value: $0.1, help: $0.2) }
            }
            if !rows.isEmpty { sections.append(InfoSection(title: group.rawValue, rows: rows)) }
        }

        var apple: [InfoRow] = []
        let xcodes = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted()
        for name in xcodes {
            let url = URL(fileURLWithPath: "/Applications/\(name)")
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            let build = NSDictionary(contentsOf: url.appendingPathComponent("Contents/version.plist"))?["ProductBuildVersion"] as? String
            if let version = info?["CFBundleShortVersionString"] as? String {
                apple.append(InfoRow(label: name.replacingOccurrences(of: ".app", with: ""), value: version + (build.map { " (\($0))" } ?? ""), help: url.path))
            }
        }
        if hasDeveloperTools, let selected = await Shell.run("/usr/bin/xcode-select", ["-p"]) {
            apple.append(InfoRow(label: "Active developer folder", value: selected.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let tools = await Shell.run("/usr/sbin/pkgutil", ["--pkg-info=com.apple.pkg.CLTools_Executables"]), tools.status == 0,
           let version = tools.output.split(separator: "\n").first(where: { $0.hasPrefix("version:") }) {
            let full = InfoRules.version(in: String(version)) ?? String(version)
            apple.append(InfoRow(label: "Command Line Tools", value: full.split(separator: ".").prefix(2).joined(separator: "."), help: full))
        }
        if !apple.isEmpty { sections.insert(InfoSection(title: "Xcode", rows: apple), at: 0) }

        let appNames = ["Android Studio", "Visual Studio Code", "Cursor", "Zed", "Docker", "OrbStack", "IntelliJ IDEA", "IntelliJ IDEA CE",
                        "PyCharm", "PyCharm CE", "WebStorm", "Rider", "GoLand", "CLion", "Fleet", "Sublime Text", "Nova", "Postman",
                        "TablePlus", "Insomnia", "GitHub Desktop", "Tower", "Fork", "Sourcetree", "Simulator"]
        let apps: [InfoRow] = appNames.compactMap { name in
            let url = ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: "\($0)/\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url, let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let version = info["CFBundleShortVersionString"] as? String else { return nil }
            return InfoRow(label: name, value: version, help: url.path)
        }
        if !apps.isEmpty { sections.append(InfoSection(title: "Apps", rows: apps)) }
        return sections
    }

    /// The PATH people get in Terminal, so tools from Homebrew, nvm or
    /// pyenv are found. Apps started from Finder get a much shorter one.
    private static func toolEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let marker = "__TOOLBELT_PATH__"
        if let result = await Shell.run(shell, ["-lic", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 6),
           let start = result.output.range(of: marker),
           let end = result.output.range(of: marker, range: start.upperBound..<result.output.endIndex) {
            environment["PATH"] = String(result.output[start.upperBound..<end.lowerBound])
        } else {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // Never download or update anything just to print a version.
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        environment["COREPACK_ENABLE_NETWORK"] = "0"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_NOLOGO"] = "1"
        environment["NO_UPDATE_NOTIFIER"] = "1"
        return environment
    }
}
