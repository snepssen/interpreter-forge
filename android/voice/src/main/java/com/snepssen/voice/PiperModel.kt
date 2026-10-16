package com.snepssen.voice

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.json.JSONObject
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * A Piper voice: its config, its ONNX session and one inference call.
 * voice-core's PiperModel in Kotlin: Piper's plain id layout, and for a graph
 * with Voice Forge's duration input, ones, which is the stock voice exactly.
 */
class PiperModel(model: File, config: File = File(model.path + ".json")) : AutoCloseable {
    class Polyglot(val languages: List<String>, val lengthScale: Map<String, Double>, val epoch: Int?, val status: String?)

    val sampleRate: Int
    val espeakVoice: String
    val noiseScale: Double
    val lengthScale: Double
    val noiseW: Double
    val phonemeIdMap: Map<String, IntArray>
    val polyglot: Polyglot?
    val takesDurationFactors: Boolean

    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession

    init {
        val json = JSONObject(config.readText())
        sampleRate = json.getJSONObject("audio").getInt("sample_rate")
        espeakVoice = json.getJSONObject("espeak").getString("voice")
        json.getJSONObject("inference").let {
            noiseScale = it.getDouble("noise_scale"); lengthScale = it.getDouble("length_scale"); noiseW = it.getDouble("noise_w")
        }
        val map = json.getJSONObject("phoneme_id_map")
        phonemeIdMap = map.keys().asSequence().associateWith { key ->
            val ids = map.getJSONArray(key); IntArray(ids.length()) { ids.getInt(it) }
        }
        polyglot = json.optJSONObject("polyglot")?.let { p ->
            val langs = p.getJSONArray("languages")
            val scales = p.optJSONObject("length_scale")
            Polyglot(List(langs.length()) { langs.getString(it) },
                     scales?.keys()?.asSequence()?.associateWith { scales.getDouble(it) } ?: emptyMap(),
                     if (p.has("epoch")) p.getInt("epoch") else null, p.optString("status").ifEmpty { null })
        }
        session = env.createSession(model.absolutePath, OrtSession.SessionOptions())
        takesDurationFactors = DURATION_FACTORS in session.inputNames
    }

    /** `^`, a pad, each known symbol and a pad, `trailingPads` more pads, `$`. */
    fun ids(phonemes: String, trailingPads: Int = 0): IntArray {
        val pad = phonemeIdMap["_"] ?: IntArray(0)
        val out = ArrayList<Int>()
        out += (phonemeIdMap["^"] ?: IntArray(0)).toList(); out += pad.toList()
        phonemes.codePoints().forEach { point ->
            phonemeIdMap[String(Character.toChars(point))]?.let { out += it.toList(); out += pad.toList() }
        }
        repeat(trailingPads) { out += pad.toList() }
        out += (phonemeIdMap["$"] ?: IntArray(0)).toList()
        return out.toIntArray()
    }

    /** One inference call; scales in the model's order: noise, length, noise_w. */
    fun infer(ids: IntArray, noiseScale: Double, lengthScale: Double, noiseW: Double, durationFactors: FloatArray? = null): FloatArray {
        val n = ids.size.toLong()
        val inputs = mutableMapOf(
            "input" to OnnxTensor.createTensor(env, LongBuffer.wrap(LongArray(ids.size) { ids[it].toLong() }), longArrayOf(1, n)),
            "input_lengths" to OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(n)), longArrayOf(1)),
            "scales" to OnnxTensor.createTensor(env, FloatBuffer.wrap(floatArrayOf(noiseScale.toFloat(), lengthScale.toFloat(), noiseW.toFloat())), longArrayOf(3)),
        )
        if (takesDurationFactors) {
            val factors = durationFactors ?: FloatArray(ids.size) { 1f }
            inputs[DURATION_FACTORS] = OnnxTensor.createTensor(env, FloatBuffer.wrap(factors), longArrayOf(1, 1, n))
        }
        try {
            session.run(inputs, setOf("output")).use { result ->
                val tensor = result.get("output").get() as OnnxTensor
                val buffer = tensor.floatBuffer
                return FloatArray(buffer.remaining()).also { buffer.get(it) }
            }
        } finally {
            inputs.values.forEach { it.close() }
        }
    }

    override fun close() = session.close()

    companion object { const val DURATION_FACTORS = "vf_duration_factors" }
}
