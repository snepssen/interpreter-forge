package com.snepssen.core

/**
 * Decides when enough of the speech has arrived to hand a piece on. The
 * iPhone app's Segmenter (itself a port of segmenter.py), held to the same
 * cases. Words are committed once two passes agree on them and only at a
 * safe place: a sentence end with agreed speech after it, a short pause the
 * judge accepts, a long pause, a comma past the soft limit, or a forced cut.
 */
data class SegmenterConfig(
    val hop: Double = 0.5,  // seconds of audio between ASR passes
    val leftContext: Double = 0.5,  // committed audio re-fed ahead of the mark
    val longPause: Double = 1.4,  // silence that commits everything said so far
    val softSegment: Double = 4.0,  // uncommitted speech past which a comma will do
    val maxSegment: Double = 5.0,  // uncommitted speech that forces a cut the judge accepts
    val hardSegment: Double = 6.0,  // uncommitted speech that forces a cut, accepted or not
    val minWords: Int = 3,  // shorter sentences wait to join the next one
    val adapt: Boolean = true,  // stretch the long pause to the speaker's hesitations
    val maxLongPause: Double = 3.0,  // ceiling on the adapted long pause
    val judgePause: Double = 0.4,  // silence after which the judge is asked
    val judgeTries: Int = 3,  // candidate cut points put to the judge per decision
)

private val sentenceEnd = setOf('.', '?', '!')
private val clauseEnd = setOf(',', ';', ':', '—', '–')
private const val TIMING_SLOP = 0.12  // ASR word times wander about this much between passes
private const val STABLE_SHARE = 0.8  // of a prefix's words that must agree with the last pass

fun endsSentence(text: String): Boolean {
    val last = text.lastOrNull() ?: return false
    if (last !in sentenceEnd) return false
    return !text.endsWith("...") && !text.endsWith("…")
}

/** What must agree between passes: the word, and whether it ends a sentence. */
private data class Key(val word: String, val ends: Boolean) {
    constructor(w: Word) : this(w.text.lowercase().filter { it.isLetterOrDigit() || it == '_' }, endsSentence(w.text))
}

class Segmenter(val config: SegmenterConfig = SegmenterConfig(), var judge: (suspend (String) -> Boolean)? = null) {
    var mark = 0.0  // stream time up to which everything is committed
    var pending: List<Word> = emptyList(); private set  // the latest hypothesis for what is not committed
    private var last: Word? = null
    private val gaps = ArrayList<Double>()
    private val verdicts = HashMap<String, Boolean>()
    private var count = 0

    fun longPauseThreshold(): Double {
        if (!config.adapt || gaps.size < 8) return config.longPause
        return minOf(maxOf(config.longPause, percentile(gaps, 98.0) * 1.6), config.maxLongPause)
    }

    /** Where the next ASR window should begin, in stream seconds. */
    fun windowStart() = maxOf(0.0, mark - config.leftContext)

    /** Drop the re-recognised left context, keeping words past the mark. */
    fun newWords(words: List<Word>): List<Word> {
        val kept = words.filter { (it.start + it.end) / 2 >= mark - TIMING_SLOP }.toMutableList()
        val first = kept.firstOrNull(); val last = last
        if (first != null && last != null &&
            (first.start < mark - TIMING_SLOP || (first.start < mark && Key(first).word == Key(last).word))) {
            kept.removeAt(0)  // the committed word again, re-heard or re-timed
        }
        return kept
    }

    /** Advance with the latest hypothesis for the uncommitted tail (already through newWords). */
    suspend fun step(now: Double, words: List<Word>, silence: Double): List<Segment> {
        var rest = words
        var agreed = agreed(pending, rest)
        val segments = mutableListOf<Segment>()
        while (rest.isNotEmpty()) {
            // The VAD can go on hearing "speech" long after the last transcribable word: that is a pause too.
            val heardGap = now - rest.last().end
            val (cut, reason) = decide(rest, agreed, silence, heardGap)
            if (cut == 0) break
            segments += commit(rest.subList(0, cut), reason, now)
            rest = rest.subList(cut, rest.size)
            agreed = agreed.subList(cut, agreed.size)
        }
        pending = rest
        return segments
    }

    /** End of stream: commit whatever is left. */
    fun flush(now: Double, words: List<Word>): List<Segment> {
        pending = emptyList()
        return if (words.isEmpty()) emptyList() else listOf(commit(words, "flush", now))
    }

    /** Slide the mark through silence so ASR windows stay short. */
    fun advanceIdle(now: Double) { if (pending.isEmpty()) mark = maxOf(mark, now - config.leftContext) }

    private suspend fun decide(words: List<Word>, agreed: List<Boolean>, silence: Double, heardGap: Double): Pair<Int, String> {
        val c = config
        if (maxOf(silence, heardGap) >= longPauseThreshold()) return words.size to "pause"

        // Latest sentence end with stable speech after it.
        val stable = stable(agreed)
        if (stable >= 2) {
            for (i in stable - 2 downTo 0) {
                if (endsSentence(words[i].text) && agreed[i] && agreed[i + 1] && i + 1 >= c.minWords) return (i + 1) to "sentence"
            }
        }
        if (judge != null && silence >= c.judgePause && stable == words.size && words.size >= c.minWords && complete(words)) {
            return words.size to "judged"
        }
        val span = words.last().end - words.first().start
        if (span >= c.softSegment) {
            val cut = firstComplete(words, clauseCuts(words, stable))
            if (cut > 0) return cut to "clause"
        }
        if (span >= c.maxSegment && stable >= 2) {
            val cuts = clauseCuts(words, stable) + gapCuts(words, stable)
            if (judge == null) return (cuts.firstOrNull() ?: (stable - 1)) to "force"
            // No cut it accepts: better late than wrong, up to the cap below.
            val cut = firstComplete(words, listOf(stable) + cuts)
            if (cut > 0) return cut to "force"
        }
        if (span >= c.hardSegment) {  // never settles, or nothing acceptable: cut what we have
            val cuts = clauseCuts(words, words.size) + gapCuts(words, words.size)
            return (cuts.firstOrNull() ?: words.size) to "force"
        }
        return 0 to ""
    }

    /** The first cut whose words stand alone; without a judge, simply the first. */
    private suspend fun firstComplete(words: List<Word>, cuts: List<Int>): Int {
        if (judge == null) return cuts.firstOrNull() ?: 0
        for (cut in cuts.take(config.judgeTries)) if (complete(words.subList(0, cut))) return cut
        return 0
    }

    private suspend fun complete(words: List<Word>): Boolean {
        val text = words.joinToString(" ") { it.text }
        verdicts[text]?.let { return it }
        if (verdicts.size > 256) verdicts.clear()
        val verdict = judge?.invoke(text) ?: true
        verdicts[text] = verdict
        return verdict
    }

    private fun commit(words: List<Word>, reason: String, now: Double): Segment {
        for ((a, b) in words.zipWithNext()) if (!endsSentence(a.text)) gaps += maxOf(0.0, b.start - a.end)
        if (gaps.size > 200) repeat(gaps.size - 200) { gaps.removeAt(0) }
        mark = words.last().end
        last = words.last()
        return Segment(count++, words.toList(), reason, now)
    }

    companion object {
        /** Which of `words` the previous pass also heard, aligned word by word. */
        fun agreed(previous: List<Word>, words: List<Word>): List<Boolean> {
            val agreed = BooleanArray(words.size)
            for (block in SequenceMatcher(previous.map(::Key), words.map(::Key)).matchingBlocks()) {
                for (j in block.j until block.j + block.n) agreed[j] = true
            }
            return agreed.toList()
        }

        /** Longest prefix ending on an agreed word with STABLE_SHARE of its words agreed. */
        fun stable(agreed: List<Boolean>): Int {
            var best = 0; var count = 0
            agreed.forEachIndexed { index, ok ->
                val n = index + 1
                if (ok) count++
                if (ok && count >= STABLE_SHARE * n) best = n
            }
            return best
        }

        /** Cuts after clause marks in the first `stable` words, latest first. */
        fun clauseCuts(words: List<Word>, stable: Int): List<Int> {
            if (stable < 2) return emptyList()
            return (stable - 2 downTo 0).filter { i -> words[i].text.lastOrNull()?.let { it in clauseEnd } == true && longEnough(words, i) }
                .map { it + 1 }
        }

        /** Cuts at the gaps between the first `stable` words, widest first. */
        fun gapCuts(words: List<Word>, stable: Int): List<Int> {
            if (stable < 2) return emptyList()
            return (0 until stable - 1).filter { longEnough(words, it) }
                .map { (words[it + 1].start - words[it].end) to it }
                .sortedWith(compareByDescending<Pair<Double, Int>> { it.first }.thenByDescending { it.second })  // as Python's sorted(reverse=True)
                .map { it.second + 1 }
        }

        /** A cut after word i keeps at least 40% of the pending speech (or 3 s) in front. */
        fun longEnough(words: List<Word>, i: Int): Boolean {
            val span = words.last().end - words.first().start
            return words[i].end - words.first().start >= minOf(0.4 * span, 3.0)
        }
    }
}

/** numpy.percentile with its default linear interpolation. */
fun percentile(values: List<Double>, p: Double): Double {
    val sorted = values.sorted()
    val rank = p / 100 * (sorted.size - 1)
    val lo = kotlin.math.floor(rank).toInt(); val hi = kotlin.math.ceil(rank).toInt()
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
}
