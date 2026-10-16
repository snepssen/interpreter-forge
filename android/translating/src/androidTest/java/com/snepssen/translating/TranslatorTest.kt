package com.snepssen.translating

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Both translators on the device: llama.cpp reads each prompt into exactly the
 * tokens the model's own tokenizer makes (prompts.json), and translates. The
 * GGUF files are copied into this app's files by scripts/test-translating.sh.
 */
@RunWith(AndroidJUnit4::class)
class TranslatorTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target = instrumentation.targetContext
    private val fixtures = JSONObject(instrumentation.context.assets.open("prompts.json").bufferedReader().readText())
    private val report = StringBuilder()

    private fun check(model: String, file: String, noSpacePrefix: Boolean = false, translate: (Llm) -> Unit) {
        val started = System.nanoTime()
        Llm(target, File(target.filesDir, file), noSpacePrefix = noSpacePrefix).use { llm ->
            report.appendLine("$model loaded in %.1f s".format((System.nanoTime() - started) / 1e9))
            val cases = fixtures.getJSONArray(model)
            for (i in 0 until cases.length()) {
                val c = cases.getJSONObject(i)
                val ids = c.getJSONArray("ids").let { a -> IntArray(a.length()) { a.getInt(it) } }
                assertArrayEquals("$model tokens: ${c.getString("text")}", ids, llm.tokenize(c.getString("prompt")))
            }
            report.appendLine("$model: ${cases.length()} prompts tokenized exactly as its own tokenizer does")
            translate(llm)
        }
    }

    private fun timed(llm: Llm, label: String, prompt: String): String {
        val started = System.nanoTime()
        val out = llm.generate(prompt, 96).trim()
        report.appendLine("  $label → $out   (%.0f ms)".format((System.nanoTime() - started) / 1e6))
        assertTrue("$label: nothing translated", out.isNotEmpty())
        return out
    }

    @Test fun translators() {
        try {
            check("translategemma", "translategemma-4b-it.Q4_K_M.gguf") { llm ->
                timed(llm, "pl→en Nie mój cyrk, nie moje małpy.", Prompts.translateGemma(emptyList(), "pl", "Nie mój cyrk, nie moje małpy.", "en"))
                timed(llm, "de→hu Der Zug fällt wegen Bauarbeiten aus.", Prompts.translateGemma(emptyList(), "de", "Der Zug fällt wegen Bauarbeiten aus.", "hu"))
                val first = timed(llm, "hu→pl Nem tudom, mikor jön a busz.", Prompts.translateGemma(emptyList(), "hu", "Nem tudom, mikor jön a busz.", "pl"))
                timed(llm, "hu→pl (with context) De szerintem késik.", Prompts.translateGemma(
                    listOf(Prompts.Piece("hu", "Nem tudom, mikor jön a busz.", first)), "hu", "De szerintem késik.", "pl"))
                timed(llm, "en→it I'm going to the shop, do you need anything?", Prompts.translateGemma(emptyList(), "en", "I'm going to the shop, do you need anything?", "it"))
            }
            check("eurollm", "EuroLLM-1.7B-Instruct.Q4_K_M.gguf", noSpacePrefix = true) { llm ->
                timed(llm, "pl→en Nie mój cyrk, nie moje małpy.", Prompts.euroLLM("pl", "Nie mój cyrk, nie moje małpy.", "en"))
                timed(llm, "de→hu Der Zug fällt wegen Bauarbeiten aus.", Prompts.euroLLM("de", "Der Zug fällt wegen Bauarbeiten aus.", "hu"))
                timed(llm, "en→pl I'm going to the shop, do you need anything?", Prompts.euroLLM("en", "I'm going to the shop, do you need anything?", "pl"))
            }
        } finally {
            File(target.filesDir, "translating-report.txt").writeText(report.toString())
            println(report)
        }
    }
}
