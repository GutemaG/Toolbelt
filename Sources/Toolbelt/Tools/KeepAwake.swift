import Foundation
import IOKit.pwr_mgt

/// Keep Awake: a power assertion that stops idle sleep until a time, or
/// until turned off. Nothing runs while it is off.
@MainActor
final class KeepAwake {
    static var shared: KeepAwake!
    private let model: AppModel
    private var assertion: IOPMAssertionID = 0
    private var endTask: Task<Void, Never>?

    static let displayKey = "awake.display"
    /// Keep the display on too, not only the Mac. On by default.
    static var keepsDisplayOn: Bool { UserDefaults.standard.object(forKey: displayKey) as? Bool ?? true }

    init(model: AppModel) {
        self.model = model
    }

    var isOn: Bool { assertion != 0 }

    /// Starts, or restarts with a new length. nil keeps the Mac awake until turned off.
    func start(for duration: TimeInterval?) {
        stop()
        let type = (Self.keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Toolbelt Keep Awake" as CFString, &id) == kIOReturnSuccess else { return }
        assertion = id
        model.awakeUntil = duration.map { Date.now.addingTimeInterval($0) } ?? .distantFuture
        if let duration {
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
        StatusItems.shared?.refreshIcons()
    }

    func stop() {
        endTask?.cancel()
        endTask = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        model.awakeUntil = nil
        StatusItems.shared?.refreshIcons()
    }

    /// "On until 3:45 PM", "On until you turn it off", or "Off".
    static func status(_ until: Date?) -> String {
        guard let until else { return "Off" }
        if until == .distantFuture { return "On until you turn it off" }
        return "On until " + until.formatted(date: .omitted, time: .shortened)
    }
}
