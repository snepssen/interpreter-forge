package com.snepssen.voice

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The polyglot voice speaking on Android, one joke per language, written out to be heard. */
@RunWith(AndroidJUnit4::class)
class VoiceTest {
    private val context = InstrumentationRegistry.getInstrumentation().context
    private val jokes = linkedMapOf(
        "en" to "I'm reading a book about anti-gravity. It's impossible to put down.",
        "pl" to "Przychodzi baba do lekarza. Panie doktorze, wszyscy mnie ignorują! Następny proszę.",
        "hu" to "Móricka, miért késtél el? Mert kint az volt kiírva: iskola, lassan hajts!",
        "de" to "Treffen sich zwei Jäger. Beide tot.",
        "nl" to "Wat is geel en kan niet zwemmen? Een graafmachine.",
        "fr" to "Quel est le comble pour un électricien ? Ne pas être au courant.",
        "es" to "¿Qué le dice un pez a otro pez? ¡Nada!",
        "it" to "Qual è il colmo per un giardiniere? Piantare in asso qualcuno.",
    )

    private fun asset(name: String) = File(context.filesDir, name).also { out ->
        context.assets.open("voice/$name").use { input -> out.outputStream().use { input.copyTo(it) } }
    }

    @Test fun everyLanguageSpeaks() {
        asset("snepssen-polyglot.onnx.json")
        val voice = Voice(asset("snepssen-polyglot.onnx"), EspeakData.directory(context))
        assertEquals(Polyphon.trained.toSet(), voice.languages.toSet())
        val out = context.getExternalFilesDir("speech")!!
        for ((language, text) in jokes) {
            voice.language = language
            val started = System.nanoTime()
            val samples = voice.speak(text)
            val seconds = samples.size / voice.sampleRate.toDouble()
            println("voice $language: %.1f s of speech in %.0f ms".format(seconds, (System.nanoTime() - started) / 1e6))
            assertTrue("$language spoke too little", seconds > 1.5)
            wav(File(out, "$language.wav"), samples, voice.sampleRate)
        }
    }

    private fun wav(file: File, samples: FloatArray, rate: Int) {
        val pcm = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) pcm.putShort((s.coerceIn(-1f, 1f) * 32767).toInt().toShort())
        DataOutputStream(FileOutputStream(file)).use { o ->
            fun le32(v: Int) = o.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array())
            fun le16(v: Int) = o.write(ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(v.toShort()).array())
            o.writeBytes("RIFF"); le32(36 + pcm.capacity()); o.writeBytes("WAVEfmt "); le32(16); le16(1); le16(1)
            le32(rate); le32(rate * 2); le16(2); le16(16); o.writeBytes("data"); le32(pcm.capacity()); o.write(pcm.array())
        }
    }
}
