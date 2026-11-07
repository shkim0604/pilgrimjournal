import Foundation

/// Line-based three-way merge for shared notes edited on two devices at once.
///
/// Edits to different lines are both kept, even when they touch neighbouring lines. When both sides insert new lines at the same
/// spot (family members each adding a prayer item at the end), both insertions are kept,
/// the winner's first. Only when both sides change or delete the same base lines
/// differently is it a conflict: the winner's lines are used and `hasConflicts` is set so
/// the caller can keep the losing text as a revision.
public enum ThreeWayTextMerge {
    public enum Side: Sendable {
        case local
        case remote
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var hasConflicts: Bool

        public init(text: String, hasConflicts: Bool) {
            self.text = text
            self.hasConflicts = hasConflicts
        }
    }

    public static func merge(base: String, local: String, remote: String, winner: Side) -> Result {
        if local == remote { return Result(text: local, hasConflicts: false) }
        if local == base { return Result(text: remote, hasConflicts: false) }
        if remote == base { return Result(text: local, hasConflicts: false) }

        let baseLines = lines(base)
        let localHunks = hunks(baseLines, lines(local), side: .local)
        let remoteHunks = hunks(baseLines, lines(remote), side: .remote)
        let sorted = (localHunks + remoteHunks).sorted {
            ($0.start, $0.end, $0.side == winner ? 0 : 1) < (
                $1.start, $1.end, $1.side == winner ? 0 : 1
            )
        }

        // Hunks whose base ranges overlap, or that both insert at the same spot, are
        // resolved together; everything else applies independently.
        var clusters: [[Hunk]] = []
        var clusterEnd = 0
        for hunk in sorted {
            if let first = clusters.last?.first,
                hunk.start < clusterEnd
                    || (hunk.isInsertion && first.isInsertion && hunk.start == first.start)
            {
                clusters[clusters.count - 1].append(hunk)
                clusterEnd = max(clusterEnd, hunk.end)
            } else {
                clusters.append([hunk])
                clusterEnd = hunk.end
            }
        }

        var merged: [Substring] = []
        var hasConflicts = false
        var cursor = 0
        for cluster in clusters {
            let start = cluster[0].start
            let end = cluster.map(\.end).max() ?? start
            merged += baseLines[cursor..<start]
            cursor = end

            let localPart = cluster.filter { $0.side == .local }
            let remotePart = cluster.filter { $0.side == .remote }
            if localPart.isEmpty || remotePart.isEmpty {
                merged += applying(cluster, to: baseLines, from: start, to: end)
            } else if cluster.allSatisfy(\.isInsertion) {
                let localLines = localPart.flatMap(\.lines)
                let remoteLines = remotePart.flatMap(\.lines)
                merged += winner == .local ? localLines : remoteLines
                if localLines != remoteLines {
                    merged += winner == .local ? remoteLines : localLines
                }
            } else {
                let localVersion = applying(localPart, to: baseLines, from: start, to: end)
                let remoteVersion = applying(remotePart, to: baseLines, from: start, to: end)
                if localVersion != remoteVersion { hasConflicts = true }
                merged += winner == .local ? localVersion : remoteVersion
            }
        }
        merged += baseLines[cursor...]

        return Result(text: merged.joined(separator: "\n"), hasConflicts: hasConflicts)
    }

    private struct Hunk {
        var start: Int
        var end: Int
        var lines: [Substring]
        var side: Side

        var isInsertion: Bool { start == end }
    }

    private static func lines(_ text: String) -> [Substring] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The edits that turn `base` into `other`: each replaces base lines `start..<end`.
    private static func hunks(_ base: [Substring], _ other: [Substring], side: Side) -> [Hunk] {
        var result: [Hunk] = []
        var (i, j) = (0, 0)
        for (baseIndex, otherIndex) in matches(base, other).enumerated() {
            guard let otherIndex else { continue }
            if i < baseIndex || j < otherIndex {
                result.append(
                    Hunk(start: i, end: baseIndex, lines: Array(other[j..<otherIndex]), side: side))
            }
            (i, j) = (baseIndex + 1, otherIndex + 1)
        }
        if i < base.count || j < other.count {
            result.append(Hunk(start: i, end: base.count, lines: Array(other[j...]), side: side))
        }
        return result
    }

    /// Base lines `start..<end` with one side's hunks (all inside that range) applied.
    private static func applying(
        _ hunks: [Hunk], to base: [Substring], from start: Int, to end: Int
    )
        -> [Substring]
    {
        var result: [Substring] = []
        var cursor = start
        for hunk in hunks {
            result += base[cursor..<hunk.start]
            result += hunk.lines
            cursor = hunk.end
        }
        result += base[cursor..<end]
        return result
    }

    /// For each line of `base`, the index of the line it is matched to in `other` by a
    /// longest common subsequence, or nil when the line was changed or deleted.
    private static func matches(_ base: [Substring], _ other: [Substring]) -> [Int?] {
        var result = [Int?](repeating: nil, count: base.count)
        var prefix = 0
        while prefix < base.count, prefix < other.count, base[prefix] == other[prefix] {
            result[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix, suffix < other.count - prefix,
            base[base.count - 1 - suffix] == other[other.count - 1 - suffix]
        {
            result[base.count - 1 - suffix] = other.count - 1 - suffix
            suffix += 1
        }

        let a = Array(base[prefix..<(base.count - suffix)])
        let b = Array(other[prefix..<(other.count - suffix)])
        guard !a.isEmpty, !b.isEmpty else { return result }

        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for x in stride(from: a.count - 1, through: 0, by: -1) {
            for y in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[x][y] =
                    a[x] == b[y]
                    ? lengths[x + 1][y + 1] + 1
                    : max(lengths[x + 1][y], lengths[x][y + 1])
            }
        }
        var (x, y) = (0, 0)
        while x < a.count, y < b.count {
            if a[x] == b[y] {
                result[prefix + x] = prefix + y
                x += 1
                y += 1
            } else if lengths[x + 1][y] >= lengths[x][y + 1] {
                x += 1
            } else {
                y += 1
            }
        }
        return result
    }
}
