package com.snepssen.core

/** One recognised word, timed in seconds from the start of the stream. */
data class Word(val text: String, val start: Double, val end: Double)

/** A run of words the segmenter has committed: passed on, never revised. */
data class Segment(
    val index: Int,
    val words: List<Word>,
    /** "sentence", "judged", "pause", "clause", "force" or "flush"; joined with "+" when merged. */
    val reason: String,
    /** Stream time at which the commit decision existed. */
    val decidedAt: Double,
    /** If merged: where each piece in it ended, so lag can be counted for every one. */
    val parts: List<Double> = emptyList(),
) {
    val text get() = words.joinToString(" ") { it.text }
    val start get() = words.firstOrNull()?.start ?: 0.0
    val end get() = words.lastOrNull()?.end ?: 0.0

    companion object {
        /** Several waiting pieces as one, timed from the first word to the last. */
        fun combine(segments: List<Segment>): Segment {
            if (segments.size <= 1) return segments[0]
            val reasons = segments.map { it.reason }.distinct()
            return Segment(segments.first().index, segments.flatMap { it.words }, reasons.joinToString("+"),
                           segments.last().decidedAt, segments.map { it.end })
        }
    }
}
