/// Python's `difflib.SequenceMatcher`, the parts this project uses, with no
/// junk heuristics (`autojunk=False`). Ported rather than approximated so the
/// Swift segmenter agrees with the Python one it is measured against.
struct SequenceMatcher<Element: Hashable> {
    let a: [Element]
    let b: [Element]
    private let b2j: [Element: [Int]]

    init(_ a: [Element], _ b: [Element]) {
        self.a = a
        self.b = b
        var b2j: [Element: [Int]] = [:]
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }
        self.b2j = b2j
    }

    /// (i, j, n): a[i..<i+n] == b[j..<j+n], in order, without the closing sentinel.
    func matchingBlocks() -> [(i: Int, j: Int, n: Int)] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [(i: Int, j: Int, n: Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            blocks.append((i, j, k))
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return blocks.sorted { ($0.i, $0.j) < ($1.i, $1.j) }
    }

    /// 2·matches / total length, as `SequenceMatcher.ratio()`.
    func ratio() -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        return 2 * Double(matchingBlocks().reduce(0) { $0 + $1.n }) / Double(total)
    }

    private func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var (besti, bestj, bestsize) = (alo, blo, 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var next: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                next[j] = k
                if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
            }
            j2len = next
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            (besti, bestj, bestsize) = (besti - 1, bestj - 1, bestsize + 1)
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }
}
