package com.snepssen.voice

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The Android voice held to voice-core's own fixtures: the same files the
 * Swift version passes, so both ports say exactly what the voice learned.
 */
@RunWith(AndroidJUnit4::class)
class PolyphonTest {
    private val context = InstrumentationRegistry.getInstrumentation().context
    private val data = EspeakData.directory(context)

    private fun fixture(name: String) = context.assets.open("fixtures/$name").bufferedReader().readLines()
        .filter { it.isNotEmpty() && !it.startsWith("#") }.map { it.split('\t') }

    private val map: Map<String, IntArray> by lazy {
        val json = JSONObject(context.assets.open("fixtures/phoneme_id_map.json").bufferedReader().readText())
        json.keys().asSequence().associateWith { k -> val a = json.getJSONArray(k); IntArray(a.length()) { a.getInt(it) } }
    }

    @Test fun polyphonMatchesTheTrainingPhonemizer() {
        val phonemizers = mutableMapOf<String, EspeakPhonemizer>()
        var checked = 0
        for ((language, text, ids) in fixture("polyphon_ids.tsv")) {
            val espeak = phonemizers.getOrPut(language) { EspeakPhonemizer(data, Polyphon.espeakVoice(language)) }
            val got = Polyphon.ids(Polyphon.sentences(text, language, espeak), map).toList()
            assertEquals("[$language] $text", ids.split(' ').map { it.toInt() }, got)
            checked++
        }
        assertTrue(checked > 30)
    }

    @Test fun englishMatchesVoiceForge() {
        val espeak = EspeakPhonemizer(data, "en-us")
        for ((text, ipa) in fixture("en_us_phonemes.tsv")) assertEquals(text, ipa, espeak.phonemize(text, dropFinalStop = true))
    }

    @Test fun gatewayForgeCallsAreUnchanged() {
        val gateway = EspeakPhonemizer(data, "en-us", listOf("I-There" to "Eye-There", "REBAL" to "Reeball"), spacesEmDashes = false)
        var checked = 0
        for ((sentence, ipa, ids) in fixture("gateway_forge_calls.tsv")) {
            val phonemes = gateway.phonemize(sentence, dropFinalStop = true)
            assertEquals(sentence, ipa, phonemes)
            checked++
        }
        assertTrue(checked > 300)
    }
}
