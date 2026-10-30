import Foundation

/// Joins frames of a scrolling area into one tall image. Each frame comes in
/// as a signature: one row of gray samples per pixel row, top first. The
/// stitcher finds how far the content moved up since the last kept frame and
/// records which rows of which frame make up the result.
///
/// Rows that stay put at the top and bottom (a sticky header, a toolbar) are
/// left out of the matching, and the bottom band is kept only once, at the end.
public struct ScrollStitcher: Sendable {
    /// Rows `rows` of kept frame `frame` (0 is the first frame).
    public struct Piece: Equatable, Sendable {
        public var frame: Int
        public var rows: Range<Int>

        public init(frame: Int, rows: Range<Int>) {
            self.frame = frame
            self.rows = rows
        }
    }

    public enum Step: Equatable, Sendable {
        /// The first frame, kept whole.
        case first
        /// Nothing moved; the frame is dropped.
        case same
        /// The content moved up `by` rows. Keep rows `keep` of this frame.
        case moved(by: Int, keep: Range<Int>)
        /// The frame matches nothing: scrolled too fast, scrolled up, or the
        /// content changed. The frame is dropped; the next one can still match.
        case lost
    }

    public let frameHeight: Int
    /// Rows two frames must share to be joined.
    public let minOverlap: Int
    public private(set) var pieces: [Piece] = []
    public private(set) var frameCount = 0
    private var last: [[UInt8]]?

    public init(frameHeight: Int, minOverlap: Int = 32) {
        self.frameHeight = frameHeight
        self.minOverlap = min(minOverlap, max(frameHeight / 4, 1))
    }

    /// The height of the joined image so far.
    public var height: Int { pieces.reduce(0) { $0 + $1.rows.count } }

    public mutating func add(_ rows: [[UInt8]]) -> Step {
        guard rows.count == frameHeight else { return .lost }
        guard let previous = last else {
            last = rows
            pieces = [Piece(frame: 0, rows: 0..<frameHeight)]
            frameCount = 1
            return .first
        }
        guard let match = Self.shift(from: previous, to: rows, minOverlap: minOverlap) else { return .lost }
        guard match.by > 0 else { return .same }
        let contentEnd = frameHeight - match.bottom
        // The previous frame's bottom band goes; this frame brings its own.
        trimTail(match.bottom)
        let keep = (contentEnd - match.by)..<frameHeight
        pieces.append(Piece(frame: frameCount, rows: keep))
        frameCount += 1
        last = rows
        return .moved(by: match.by, keep: keep)
    }

    private mutating func trimTail(_ count: Int) {
        var left = count
        while left > 0, let tail = pieces.last {
            if tail.rows.count <= left {
                left -= tail.rows.count
                pieces.removeLast()
            } else {
                pieces[pieces.count - 1].rows = tail.rows.lowerBound..<(tail.rows.upperBound - left)
                left = 0
            }
        }
    }

    /// How far the content moved up from `before` to `after`, with the fixed
    /// bands at the top and bottom. `by` is 0 when nothing moved, nil when no
    /// shift lines the frames up.
    public static func shift(from before: [[UInt8]], to after: [[UInt8]], minOverlap: Int) -> (by: Int, top: Int, bottom: Int)? {
        let height = before.count
        guard height == after.count, height > 0, let width = before.first?.count, width > 0 else { return nil }
        let same = width * 2 // a row whose samples differ by under 2 on average is the same row
        let band = height / 3
        var top = 0
        while top < band, difference(before[top], after[top]) <= same { top += 1 }
        var bottom = 0
        while bottom < band, difference(before[height - 1 - bottom], after[height - 1 - bottom]) <= same { bottom += 1 }
        let end = height - bottom
        if (top..<end).allSatisfy({ difference(before[$0], after[$0]) <= same }) { return (0, top, bottom) }

        // Row i of `after` shows row i + by of `before`. Compare every other
        // row, and stop a candidate as soon as it is worse than the best.
        // A shift of 0 competes too, so a blinking cursor or a spinner in a
        // still area reads as "nothing moved", not as lost.
        let maxShift = end - top - minOverlap
        guard maxShift >= 1 else { return nil }
        var best: (by: Int, score: Int)?
        for by in 0...maxShift {
            let rows = stride(from: top, to: end - by, by: 2)
            let count = (end - by - top + 1) / 2
            let limit = best.map { $0.score * count } ?? Int.max
            var total = 0
            for row in rows {
                total += difference(before[row + by], after[row])
                if total >= limit { break }
            }
            if total < limit { best = (by, total / max(count, 1)) }
        }
        // Accept an average difference under 6 per sample: compression and
        // font smoothing differ slightly; a wrong shift differs a lot.
        guard let best, best.score < width * 6 else { return nil }
        return (best.by, top, bottom)
    }

    /// The summed difference of two signature rows.
    public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return total
    }
}
