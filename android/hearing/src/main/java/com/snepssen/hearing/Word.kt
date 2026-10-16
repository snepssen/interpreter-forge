package com.snepssen.hearing

/** One recognised word, timed in seconds from the start of the stream. */
data class Word(val text: String, val start: Double, val end: Double)
