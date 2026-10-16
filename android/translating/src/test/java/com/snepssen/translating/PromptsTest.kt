package com.snepssen.translating

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** The prompts against what the models' own chat templates render. */
class PromptsTest {
    private val fixtures = JSONObject(javaClass.classLoader!!.getResource("prompts.json")!!.readText())

    @Test fun translateGemmaMatchesItsTemplate() {
        val cases = fixtures.getJSONArray("translategemma")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val h = c.getJSONArray("history")
            val history = (0 until h.length()).map { h.getJSONObject(it) }
                .map { Prompts.Piece(it.getString("source"), it.getString("text"), it.getString("translation")) }
            assertEquals(c.getString("text"), c.getString("prompt"),
                Prompts.translateGemma(history, c.getString("source"), c.getString("text"), c.getString("target")))
        }
    }

    @Test fun euroLLMMatchesItsTemplate() {
        val cases = fixtures.getJSONArray("eurollm")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(c.getString("text"), c.getString("prompt"), Prompts.euroLLM(c.getString("source"), c.getString("text"), c.getString("target")))
        }
    }
}
