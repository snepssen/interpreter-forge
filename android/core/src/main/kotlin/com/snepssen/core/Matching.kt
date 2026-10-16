package com.snepssen.core

/**
 * Python's difflib.SequenceMatcher, the parts this project uses, with no junk
 * heuristics (autojunk=False): the iPhone app's port, ported again, so both
 * agree with the Python they are measured against.
 */
class SequenceMatcher<T>(private val a: List<T>, private val b: List<T>) {
    data class Block(val i: Int, val j: Int, val n: Int)

    private val b2j: Map<T, List<Int>> = buildMap<T, MutableList<Int>> {
        b.forEachIndexed { j, element -> getOrPut(element) { mutableListOf() }.add(j) }
    }

    /** a[i until i+n] == b[j until j+n], in order, without the closing sentinel. */
    fun matchingBlocks(): List<Block> {
        val queue = ArrayDeque(listOf(intArrayOf(0, a.size, 0, b.size)))
        val blocks = mutableListOf<Block>()
        while (queue.isNotEmpty()) {
            val (alo, ahi, blo, bhi) = queue.removeLast()
            val (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            if (k <= 0) continue
            blocks += Block(i, j, k)
            if (alo < i && blo < j) queue.addLast(intArrayOf(alo, i, blo, j))
            if (i + k < ahi && j + k < bhi) queue.addLast(intArrayOf(i + k, ahi, j + k, bhi))
        }
        return blocks.sortedWith(compareBy({ it.i }, { it.j }))
    }

    /** 2·matches / total length, as SequenceMatcher.ratio(). */
    fun ratio(): Double {
        val total = a.size + b.size
        if (total == 0) return 1.0
        return 2.0 * matchingBlocks().sumOf { it.n } / total
    }

    private fun longestMatch(alo: Int, ahi: Int, blo: Int, bhi: Int): Triple<Int, Int, Int> {
        var besti = alo; var bestj = blo; var bestsize = 0
        var j2len = HashMap<Int, Int>()
        for (i in alo until ahi) {
            val next = HashMap<Int, Int>()
            for (j in b2j[a[i]] ?: emptyList()) {
                if (j < blo) continue
                if (j >= bhi) break
                val k = (j2len[j - 1] ?: 0) + 1
                next[j] = k
                if (k > bestsize) { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = next
        }
        while (besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1]) { besti--; bestj--; bestsize++ }
        while (besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize]) bestsize++
        return Triple(besti, bestj, bestsize)
    }
}
