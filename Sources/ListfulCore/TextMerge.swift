import Foundation

/// Longest-common-subsequence matching between two sequences.
enum Diff {
    /// Index pairs `(i, j)` with `a[i] == b[j]`, in increasing order, forming
    /// a longest common subsequence. A shared prefix and suffix are matched
    /// directly, so the quadratic part only covers the region that changed.
    static func matches<T: Equatable>(_ a: [T], _ b: [T]) -> [(Int, Int)] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        // lengths[i * (m + 1) + j]: LCS length of the middles from i and j on.
        var lengths = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[prefix + i] == b[prefix + j]
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }

        var result = (0..<prefix).map { ($0, $0) }
        var i = 0, j = 0
        while i < n, j < m {
            if a[prefix + i] == b[prefix + j] {
                result.append((prefix + i, prefix + j))
                i += 1
                j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        for k in 0..<suffix { result.append((a.count - suffix + k, b.count - suffix + k)) }
        return result
    }
}

/// Three-way merge of text by lines, for reconciling a list edited here with
/// the same file changed elsewhere (another Mac, via iCloud) since it was read.
public enum TextMerge {
    public enum Result: Equatable, Sendable {
        case merged(String)
        /// Both sides changed the same lines differently.
        case conflict
    }

    /// Combines the changes `mine` and `theirs` each made to `base`. Changes
    /// to different lines are both kept; lines inserted at the same place by
    /// both go in theirs-then-mine. Different changes to the same lines are
    /// a conflict.
    public static func merge(base: String, mine: String, theirs: String) -> Result {
        if mine == theirs || base == theirs { return .merged(mine) }
        if base == mine { return .merged(theirs) }

        let baseLines = lines(base)
        let hunks = (changes(from: baseLines, to: lines(mine), isMine: true)
            + changes(from: baseLines, to: lines(theirs), isMine: false))
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var output: [Substring] = []
        var position = 0
        var next = 0
        while next < hunks.count {
            // A group is a run of hunks touching overlapping base lines,
            // or several insertions at the same point.
            var group = [hunks[next]]
            let low = hunks[next].start
            var high = hunks[next].end
            next += 1
            while next < hunks.count {
                let hunk = hunks[next]
                let isOverlap = hunk.start < high
                let isSameInsertion = low == high && hunk.start == low && hunk.end == low
                guard isOverlap || isSameInsertion else { break }
                group.append(hunk)
                high = max(high, hunk.end)
                next += 1
            }

            let mineVersion = apply(group.filter(\.isMine), to: baseLines, from: low, to: high)
            let theirsVersion = apply(group.filter { !$0.isMine }, to: baseLines, from: low, to: high)
            output += baseLines[position..<low]
            if !group.contains(where: \.isMine) || mineVersion == theirsVersion {
                output += theirsVersion
            } else if !group.contains(where: { !$0.isMine }) {
                output += mineVersion
            } else if low == high {
                output += theirsVersion + mineVersion
            } else {
                return .conflict
            }
            position = high
        }
        output += baseLines[position...]
        return .merged(output.joined(separator: "\n"))
    }

    /// A replacement of base lines `start..<end` (empty for an insertion).
    private struct Hunk {
        var start: Int
        var end: Int
        var lines: [Substring]
        var isMine: Bool
    }

    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func changes(from base: [Substring], to other: [Substring], isMine: Bool) -> [Hunk] {
        var hunks: [Hunk] = []
        var b = 0, o = 0
        for (bi, oi) in Diff.matches(base, other) + [(base.count, other.count)] {
            if bi > b || oi > o {
                hunks.append(Hunk(start: b, end: bi, lines: Array(other[o..<oi]), isMine: isMine))
            }
            b = bi + 1
            o = oi + 1
        }
        return hunks
    }

    /// Base lines `low..<high` with one side's hunks (all within that range) applied.
    private static func apply(_ hunks: [Hunk], to base: [Substring], from low: Int, to high: Int) -> [Substring] {
        var result: [Substring] = []
        var position = low
        for hunk in hunks {
            result += base[position..<hunk.start]
            result += hunk.lines
            position = hunk.end
        }
        result += base[position..<high]
        return result
    }
}
