package com.snepssen.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * The Kotlin core held to the cases in the cases folder (one JSON file per part), which the iPhone app's
 * tccheck and the Python tests read too: same inputs, same answers.
 */
class ParityTest {
    /** cases/<name>.json, found by walking up from the module to the repository root. */
    private fun cases(name: String): JsonObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null && !File(dir, "cases/$name.json").isFile) dir = dir.parentFile
        val file = File(requireNotNull(dir) { "no cases/$name.json above ${System.getProperty("user.dir")}" }, "cases/$name.json")
        return Json.parseToJsonElement(file.readText()).jsonObject
    }

    private fun JsonObject.jsonPrimitive(key: String) = this[key]!!.jsonPrimitive.content
    private fun strings(element: Any?) = (element as JsonArray).map { it.jsonPrimitive.content }

    /** One word every `step` seconds from `start`, each lasting 0.3 s, per group. */
    private fun words(groups: JsonArray) = groups.flatMap { g ->
        val o = g.jsonObject
        words(o.jsonPrimitive("text"), o["start"]?.jsonPrimitive?.double ?: 0.0, o["step"]?.jsonPrimitive?.double ?: 0.4)
    }

    private fun words(text: String, start: Double = 0.0, step: Double = 0.4) =
        text.split(" ").mapIndexed { i, t -> Word(t, start + i * step, start + i * step + 0.3) }

    private fun configured(fields: JsonObject?): SegmenterConfig {
        var c = SegmenterConfig(adapt = false)
        for ((key, value) in fields ?: JsonObject(emptyMap())) {
            val v = value.jsonPrimitive
            c = when (key) {
                "hop" -> c.copy(hop = v.double)
                "leftContext" -> c.copy(leftContext = v.double)
                "longPause" -> c.copy(longPause = v.double)
                "softSegment" -> c.copy(softSegment = v.double)
                "maxSegment" -> c.copy(maxSegment = v.double)
                "hardSegment" -> c.copy(hardSegment = v.double)
                "minWords" -> c.copy(minWords = v.int)
                "maxLongPause" -> c.copy(maxLongPause = v.double)
                "judgePause" -> c.copy(judgePause = v.double)
                "judgeTries" -> c.copy(judgeTries = v.int)
                else -> error("unknown config field $key")
            }
        }
        return c
    }

    /** Complete when the text ends in one of `endings`; keeps what it was asked. */
    private class FakeJudge(val endings: List<String>) {
        val asked = mutableListOf<String>()
        suspend operator fun invoke(text: String): Boolean {
            asked += text
            val trimmed = text.trim('.', ',')
            return endings.any { trimmed.endsWith(it) }
        }
    }

    /** Runs every case, then fails once, naming each case that answered differently. */
    private fun all(label: String, cases: List<Pair<String, () -> String?>>) {
        val failed = cases.mapNotNull { (name, run) -> run()?.let { "$name: $it" } }
        assertTrue("${failed.size} of ${cases.size} $label cases differ:\n" + failed.joinToString("\n"), failed.isEmpty())
    }

    // segmenter

    @Test fun segmenterCases() = all("segmenter", cases("segmenter")["cases"]!!.jsonArray.map { element ->
        val c = element.jsonObject
        c.jsonPrimitive("name") to { runBlocking { segmenterCase(c) } }
    })

    private suspend fun segmenterCase(c: JsonObject): String? {
        val judge = c["judge"]?.let { FakeJudge(strings(it)) }
        val s = Segmenter(configured(c["config"]?.jsonObject), judge?.let { j -> j::invoke })
        c["startMark"]?.let { s.mark = it.jsonPrimitive.double }
        for ((i, element) in c["steps"]!!.jsonArray.withIndex()) {
            val step = element.jsonObject
            val out = s.step(step["now"]!!.jsonPrimitive.double, words(step["words"]!!.jsonArray), step["silence"]!!.jsonPrimitive.double)
            step["expect"]?.jsonArray?.let { expect ->
                val matches = out.size == expect.size && out.zip(expect).all { (segment, want) ->
                    val w = want.jsonObject
                    (w["text"] == null || segment.text == w.jsonPrimitive("text")) &&
                        (w["reason"] == null || segment.reason == w.jsonPrimitive("reason"))
                }
                if (!matches) return "step $i: ${out.map { "${it.text} [${it.reason}]" }}"
            }
            step["asked"]?.let { if (judge?.asked != strings(it)) return "step $i: asked ${judge?.asked}" }
        }
        val after = c["after"]?.jsonObject ?: JsonObject(emptyMap())
        after["mark"]?.let { if (abs(s.mark - it.jsonPrimitive.double) > 1e-9) return "mark ${s.mark}" }
        after["pending"]?.let { if (s.pending.map { w -> w.text } != strings(it)) return "pending ${s.pending.map { w -> w.text }}" }
        after["asked"]?.let { if (judge?.asked != strings(it)) return "asked ${judge?.asked}" }
        c["newWords"]?.jsonObject?.let { heard ->
            val base = if (heard["fromMark"]?.jsonPrimitive?.booleanOrNull == true) s.mark else 0.0
            val given = heard["words"]!!.jsonArray.map {
                val w = it.jsonArray
                Word(w[0].jsonPrimitive.content, base + w[1].jsonPrimitive.double, base + w[2].jsonPrimitive.double)
            }
            val kept = s.newWords(given).map { it.text }
            if (kept != strings(heard["expect"])) return "new words $kept"
        }
        return null
    }

    @Test fun pausesStretchForAHesitantSpeaker() = runBlocking {
        // Compares thresholds, not outputs, so it stays here rather than in cases/.
        val s = Segmenter(SegmenterConfig(adapt = true))
        val base = s.longPauseThreshold()
        for (i in 0 until 10) s.step(0.0, words("ein sehr langsamer Satz.", start = i * 10.0, step = 1.2), 9.0)
        assertTrue(base < s.longPauseThreshold() && s.longPauseThreshold() <= s.config.maxLongPause)
    }

    // clock times

    @Test fun clockTimes() {
        val clock = cases("clock")
        all("clock", clock["becomeDigits"]!!.jsonArray.map { pair ->
            val (source, expected) = strings(pair)
            source to { Clock.normalise(source).takeIf { it != expected } }
        } + clock["leftAlone"]!!.jsonArray.map { element ->
            val text = element.jsonPrimitive.content
            text to { Clock.normalise(text).takeIf { it != text } }
        })
    }

    // echoes

    @Test fun echoes() {
        val echo = cases("echoes")
        all("echo", echo["echoes"]!!.jsonArray.map { pair ->
            val (source, translation) = strings(pair)
            translation to { if (echoes(source, translation)) null else "not an echo" }
        } + echo["notEchoes"]!!.jsonArray.map { pair ->
            val (source, translation) = strings(pair)
            translation to { if (!echoes(source, translation)) null else "an echo" }
        })
    }

    // language evidence

    @Test fun languageEvidence() {
        all("language evidence", cases("language-evidence")["cases"]!!.jsonArray.map { element ->
            val c = element.jsonObject
            val text = c.jsonPrimitive("text")
            text to {
                val got = Languages.evidence(text, strings(c["expected"]))
                val want = c["evidence"]!!
                val right = when {
                    want is JsonNull -> got == null
                    want.jsonPrimitive.isString -> got != false  // "notFalse"
                    else -> got == want.jsonPrimitive.boolean
                }
                if (right) null else "got $got"
            }
        })
        assertEquals("Polish, Hungarian and Dutch", Languages.list(listOf("pl", "hu", "nl")))
    }

    // catch-up

    @Test fun catchUp() {
        val backlog = Backlog()
        val catchUp = cases("catch-up")
        all("catch-up", catchUp["brief"]!!.jsonArray.map { pair ->
            val p = pair.jsonArray
            "brief at ${p[0]}" to { if (backlog.brief(p[0].jsonPrimitive.double) == p[1].jsonPrimitive.boolean) null else "differs" }
        } + catchUp["pace"]!!.jsonArray.map { pair ->
            val p = pair.jsonArray
            "pace at ${p[0]}" to {
                val got = backlog.pace(p[0].jsonPrimitive.double)
                if (abs(got - p[1].jsonPrimitive.double) < 1e-9) null else "got $got"
            }
        })
    }

    // the commentary guard (the iPhone app's SpokenTests)

    @Test fun commentaryIsCaughtButTranslationsAreNot() {
        for (line in listOf("I'm sorry, but I can't translate that because it contains offensive language.",
                            "I cannot help with translating this content.", "This phrase contains profanity.",
                            "As an AI, I won't repeat that.", "Note: the original uses vulgar language.",
                            "I am not able to provide a translation of derogatory terms.")) {
            assertTrue(line, TranslationQuality.concern("Ty kurwo jebana, oddaj mi telefon.", line) != null)
        }
        for (line in listOf("I'm sorry, I didn't hear you.", "You fucking whore, give me back my phone.", "That's offensive, you know.",
                            "I can't help it, I'm tired.", "Get out of my room!", "Damn it, I've forgotten my keys again.")) {
            assertNull(line, TranslationQuality.concern("Kurwa.", line))
        }
    }
}
