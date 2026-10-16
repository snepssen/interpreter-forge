package com.snepssen.core

/**
 * The "translation" is mostly the source again: English the ASR garbled too
 * badly for the English check to pass, which the model then repeats. Over a
 * 70-minute conversation 40 of 101 interpreted pieces were this, and no real
 * translation scored above 0.6.
 */
fun echoes(source: String, translation: String): Boolean {
    fun words(t: String) = t.lowercase().filter { it.isLetterOrDigit() || it == '_' || it.isWhitespace() }
        .split(Regex("\\s+")).filter { it.isNotEmpty() }
    return SequenceMatcher(words(source), words(translation)).ratio() >= 0.6
}
