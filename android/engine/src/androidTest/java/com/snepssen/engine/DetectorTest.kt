package com.snepssen.engine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Android's language detector against the one the iPhone app uses: short
 * everyday lines of known language (Apple's detector names 75 of 76), and
 * every line heard in the kitchen recording and the phone tests, labelled by
 * Apple's (detection-apple.tsv, made with NLLanguageRecognizer).
 */
@RunWith(AndroidJUnit4::class)
class DetectorTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val detector = LanguageDetector(instrumentation.targetContext)
    private fun rows(name: String) =
        instrumentation.context.assets.open(name).bufferedReader().readLines().map { it.split("\t") }

    @Test fun knownLinesAreNamed() {
        val rows = rows("detection-truth.tsv")
        val misses = rows.filter { (text, code) -> detector.guess(text)?.code != code }
        println("detector: ${rows.size - misses.size} of ${rows.size} known lines; missed ${misses.map { it[0] }}")
        assertTrue("missed ${misses.map { it[0] }}", misses.size <= 2)
    }

    @Test fun agreesWithTheIphone() {
        val rows = rows("detection-apple.tsv")
        val agree = rows.count { (text, code) -> detector.guess(text)?.code == code }
        println("detector: agrees with Apple's on $agree of ${rows.size} heard lines")
        assertTrue("agrees on only $agree of ${rows.size}", agree >= rows.size * 95 / 100)
    }
}
