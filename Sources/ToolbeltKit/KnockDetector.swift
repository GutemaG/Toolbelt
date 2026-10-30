import Foundation

/// Finds knocks in the MacBook's motion sensor readings. Feed it every
/// reading (about 800 a second, in g); it answers when a group of one to three
/// knocks has ended, or why a jolt did not count.
///
/// A knock is a short, sharp jolt: it rises within a few milliseconds and dies
/// out within about 100 ms. Typing, setting the laptop down and carrying it
/// are slower, or come in bursts, and are left out. The approach follows
/// mactap (MIT, github.com/jaskirat1616/mactap-app).
///
/// The side comes from the first sideways push: a knock on the right edge
/// shoves the case one way along x before it rings. Only the first ~34 ms
/// count, measured from how x sat just before the knock.
public enum KnockSide: String, CaseIterable, Sendable {
    case left, right
}

public struct KnockDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// One to three knocks in a row, and the edge the first one hit.
        case knocks(Int, KnockSide)
        case ignored(Reason)
    }

    public enum Reason: String, Sendable {
        /// A key was pressed just before.
        case typing = "Typing"
        /// The jolt lasted too long to be a knock, like a bump or the laptop moving.
        case slow = "Too slow for a knock"
        /// Barely above the background shake.
        case weak = "Too light"
        /// Many jolts at once, like drumming on the desk.
        case burst = "Too many at once"
    }

    /// 0 needs a firm knock, 1 hears a light tap.
    public var sensitivity: Double
    /// The longest pause between knocks of one group, in seconds.
    public var gap: Double
    /// Watch each knock a little longer to tell left from right.
    public var findsSide = false
    /// For a Mac whose sensor reads the sides the other way round.
    public var invertSides = false

    /// The movement right now, without gravity, in g. For a live meter.
    public private(set) var level: Double = 0
    /// What a jolt must reach to start a knock, in g.
    public private(set) var threshold: Double = 0.05

    private var gravity: (x: Double, y: Double, z: Double)?
    private var averageTotal = 1.0
    private var noise = 0.006
    private var capture: (start: Double, peak: Double)?
    private var lastKnock = -1.0
    private var count = 0
    private var deadline = 0.0
    private var recent: [Double] = []
    private var lockedUntil = -1.0
    /// After a slow jolt, nothing counts until the movement settles.
    private var waitForQuiet = false
    private var side = KnockSide.left
    /// The first sideways push of the knock being captured.
    private var push = (baseline: 0.0, weighted: 0.0, weights: 0.0, peak: 0.0)
    /// Sideways movement of the last 120 ms, for the baseline.
    private var history = [(time: Double, x: Double)](repeating: (-1, 0), count: 96)
    private var historyIndex = 0

    private let settle = 0.07      // after a knock, its ringing is not a second knock
    private let longest = 0.12     // a knock is over within this
    private let burstWindow = 0.5  // four jolts within this are drumming or typing
    private let burstLockout = 0.4

    public init(sensitivity: Double = 0.6, gap: Double = 0.35) {
        self.sensitivity = sensitivity
        self.gap = gap
    }

    /// The smallest jolt that can count, from the sensitivity: 0.05 g down to 0.012 g.
    var floor: Double { 0.05 - min(max(sensitivity, 0), 1) * 0.038 }

    /// One reading: time in seconds and the three axes in g. `typing` is true
    /// when a key went down in the last half second.
    public mutating func add(time: Double, x: Double, y: Double, z: Double, typing: Bool) -> Event? {
        // The group ends when no knock follows within the gap.
        var finished: Event?
        if count > 0, time >= deadline {
            finished = .knocks(count, side)
            count = 0
        }

        // Gravity is what stays: a slow average of each axis. While something
        // moves the laptop it follows far slower, so a bump does not leave a
        // wrong gravity behind that looks like movement afterwards.
        var g = gravity ?? (x, y, z)
        var (dx, dy, dz) = (x - g.x, y - g.y, z - g.z)
        let rate = (dx * dx + dy * dy + dz * dz).squareRoot() < threshold ? 0.0025 : 0.0005
        g = (g.x + dx * rate, g.y + dy * rate, g.z + dz * rate)
        gravity = g
        (dx, dy, dz) = (x - g.x, y - g.y, z - g.z)
        let movement = (dx * dx + dy * dy + dz * dz).squareRoot()
        let total = (x * x + y * y + z * z).squareRoot()
        averageTotal += (total - averageTotal) * 0.02
        let jump = abs(total - averageTotal)
        level = movement
        history[historyIndex] = (time, dx)
        historyIndex = (historyIndex + 1) % history.count

        // The background shake, learned from the quiet moments.
        if movement < floor * 0.9 { noise += (movement - noise) * 0.02 }
        noise = min(max(noise, 0.0035), 0.03)
        threshold = max(floor * 0.88, noise * (3 - sensitivity * 1.2))

        if movement < threshold { waitForQuiet = false }

        if var current = capture {
            current.peak = max(current.peak, movement)
            capture = current
            let length = time - current.start
            if length <= 0.034 { addPush(dx, after: length) }
            if movement < current.peak * 0.35, length >= (findsSide ? 0.034 : 0.006) {
                return finish(time: time, peak: current.peak, typing: typing) ?? finished
            }
            if length > longest {
                capture = nil
                waitForQuiet = true
                return finished ?? .ignored(.slow)
            }
        } else if !waitForQuiet, time - lastKnock > settle, time >= lockedUntil, movement > threshold, jump > max(0.022, threshold * 0.65) {
            if typing { return finished ?? .ignored(.typing) }
            capture = (time, movement)
            startPush(at: time)
            addPush(dx, after: 0)
        }
        return finished
    }

    // MARK: Which side

    /// How x sat 12 to 100 ms before the knock: what is left of gravity, not the knock.
    private mutating func startPush(at time: Double) {
        let before = history.filter { time - $0.time > 0.012 && time - $0.time < 0.1 }
        push = (before.count >= 4 ? before.reduce(0) { $0 + $1.x } / Double(before.count) : 0, 0, 0, 0)
    }

    /// Early readings weigh most: the later ringing swings both ways.
    private mutating func addPush(_ x: Double, after age: Double) {
        let dx = x - push.baseline
        let weight = exp(-age / 0.011)
        push.weighted += dx * weight
        push.weights += weight
        if abs(dx) > abs(push.peak) { push.peak = dx }
    }

    /// Two votes, the weighted average and the strongest push; +x is right.
    private var pushSide: KnockSide {
        let sign = invertSides ? -1.0 : 1.0
        let average = sign * (push.weights > 0 ? push.weighted / push.weights : 0)
        let peak = sign * push.peak
        var votes = 0
        if abs(average) >= 0.0024 { votes += average > 0 ? 1 : -1 }
        if abs(peak) >= 0.004 { votes += peak > 0 ? 1 : -1 }
        if votes != 0 { return votes > 0 ? .right : .left }
        return average >= 0 ? .right : .left
    }

    private mutating func finish(time: Double, peak: Double, typing: Bool) -> Event? {
        capture = nil
        if typing { return .ignored(.typing) }
        if peak / noise < 1.6 { return .ignored(.weak) }
        recent = recent.filter { time - $0 < burstWindow } + [time]
        if recent.count >= 4 {
            recent = []
            count = 0
            lockedUntil = time + burstLockout
            return .ignored(.burst)
        }
        lastKnock = time
        let knockSide = pushSide
        // A clear knock on the other edge ends the group and starts a new one.
        if count > 0, findsSide, knockSide != side, abs(push.peak) > 0.008 {
            let ended = Event.knocks(count, side)
            count = 1
            side = knockSide
            deadline = time + gap
            return ended
        }
        if count == 0 { side = knockSide }
        count += 1
        deadline = time + gap
        // Waits out the gap even after three, so a fourth turns it into drumming.
        if count > 3 {
            count = 0
            lockedUntil = time + burstLockout
            return .ignored(.burst)
        }
        return nil
    }
}
