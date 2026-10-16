package com.snepssen.interpreter

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.snepssen.core.Languages
import com.snepssen.engine.Bundled
import com.snepssen.engine.Hearing
import com.snepssen.engine.LanguageDetector
import com.snepssen.engine.Linguist
import com.snepssen.engine.Microphone
import com.snepssen.engine.ModelStore
import com.snepssen.engine.Pipeline
import com.snepssen.engine.PipelineEvent
import com.snepssen.engine.Silence
import com.snepssen.engine.Threads
import com.snepssen.engine.TranslationModel
import com.snepssen.hearing.Recognizer
import com.snepssen.voice.Polyphon
import com.snepssen.voice.PolyglotVoice
import com.snepssen.voice.Voice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Everything the app shows and controls: the iPhone app's LiveSession, for
 * Android. Settings are remembered between launches.
 */
class Session(application: Application) : AndroidViewModel(application) {
    sealed interface Phase {
        data object Idle : Phase
        /** No translation model downloaded yet: the picker's turn. */
        data object ChoosingModel : Phase
        data class Loading(val what: String) : Phase
        data object Ready : Phase
        data object Live : Phase
        data class Failed(val why: String) : Phase
    }

    /** One piece of speech and what became of it. */
    data class Line(
        val id: Int,
        val source: String,
        val translation: String? = null,
        val silence: Silence? = null,
        val lag: Double? = null,
        val pace: Double = 1.0,
        /** Who spoke it, when the detector is sure: for the line's language chip. */
        val language: String? = null,
    )

    private val context: Context get() = getApplication()
    private val prefs = application.getSharedPreferences("interpreter", Context.MODE_PRIVATE)

    var phase by mutableStateOf<Phase>(Phase.Idle); private set
    val lines = mutableStateListOf<Line>()
    var hearing by mutableStateOf(""); private set
    var level by mutableStateOf(0f); private set
    /** The interpreter's voice is playing right now. */
    var speaking by mutableStateOf(false); private set
    var notice by mutableStateOf<String?>(null)
    /** Downloads under way, from 0 to 1. */
    val downloads = mutableStateMapOf<TranslationModel, Double>()
    var hearingDownload by mutableStateOf<Double?>(null); private set
    /** Bumped when models come or go, so views listing them look again. */
    var storeChanges by mutableStateOf(0); private set
    var busy by mutableStateOf(false); private set

    // settings

    /** The language the listener hears: everything is interpreted into it and the voice speaks it. */
    var target by mutableStateOf(prefs.getString("target", "en")!!); private set
    /** The languages spoken here, if restricted; empty for any. */
    var spoken by mutableStateOf(prefs.getString("spoken", "")!!.split(",").filter { it.isNotEmpty() }); private set
    /** Offer the languages the voice was not trained on: read through plain espeak-ng, with an accent. Off unless chosen. */
    var untrainedLanguages by mutableStateOf(prefs.getBoolean("untrainedLanguages", false)); private set
    /** Translations on screen only, not spoken: for a phone on the table when nobody has headphones. */
    var captionsOnly by mutableStateOf(prefs.getBoolean("captionsOnly", false)); private set
    var voiceVolume by mutableStateOf(prefs.getFloat("voiceVolume", 1f)); private set
    var showOwnLanguage by mutableStateOf(prefs.getBoolean("showOwnLanguage", true)); private set
    var translationModel by mutableStateOf(prefs.getString("translationModel", null)
        ?.let { runCatching { TranslationModel.valueOf(it) }.getOrNull() }); private set

    val targetChoices get() = trainedTargets + if (untrainedLanguages) untrainedTargets else emptyList()
    fun isTrained(code: String) = code in trainedTargets
    fun languageName(code: String) = Languages.names[code] ?: code
    val isLive get() = phase == Phase.Live

    fun chooseTarget(code: String) {
        if (code == target || isLive || busy) return
        target = code
        prefs.edit().putString("target", code).apply()
        chooseSpoken(spoken.filter { it != code })
    }

    fun chooseSpoken(codes: List<String>) {
        spoken = codes.filter { it != target }
        prefs.edit().putString("spoken", spoken.joinToString(",")).apply()
        applyLanguages()
    }

    fun chooseUntrained(on: Boolean) {
        untrainedLanguages = on
        prefs.edit().putBoolean("untrainedLanguages", on).apply()
        if (!on && target !in trainedTargets) chooseTarget("en")
    }

    fun chooseCaptionsOnly(on: Boolean) {
        captionsOnly = on
        prefs.edit().putBoolean("captionsOnly", on).apply()
        applyVoice()
    }

    fun chooseVolume(volume: Float) {
        voiceVolume = volume
        prefs.edit().putFloat("voiceVolume", volume).apply()
        applyVoice()
    }

    fun chooseShowOwnLanguage(on: Boolean) {
        showOwnLanguage = on
        prefs.edit().putBoolean("showOwnLanguage", on).apply()
    }

    private fun applyLanguages() {
        voice?.language = target
        // The linguist may be mid-translation, holding itself for a second or two.
        val (linguist, spoken, target) = Triple(linguist, spoken, target)
        viewModelScope.launch(Dispatchers.Default) { linguist?.setLanguages(spoken, target) }
    }

    private fun applyVoice() {
        pipeline?.speaks = !captionsOnly
        pipeline?.speaker?.volume = if (captionsOnly) 0f else voiceVolume
    }

    // models

    private var recognizer: Recognizer? = null
    private var linguist: Linguist? = null
    private var voice: Voice? = null
    private var pipeline: Pipeline? = null
    private var meter: Job? = null
    private var lineIDs = mutableMapOf<Int, Int>()
    private var nextLineID = 0
    private val detector by lazy { LanguageDetector(context) }

    /** The best model this phone can run; null if none fits. */
    val recommended get() = TranslationModel.recommended(context)
    fun fits(model: TranslationModel) = model.fits(context)
    fun isDownloaded(model: TranslationModel) = ModelStore.isDownloaded(context, model)

    init { viewModelScope.launch { prepare() } }

    /** Load recognition, translation and voice; download recognition if needed. */
    fun prepare() = viewModelScope.launch { load() }

    private suspend fun load() {
        if (busy || (phase != Phase.Idle && phase != Phase.ChoosingModel && phase !is Phase.Failed)) return
        val model = translationModel?.takeIf { isDownloaded(it) }
        if (model == null) { phase = Phase.ChoosingModel; return }
        busy = true
        try {
            withContext(Dispatchers.Default) {
                if (!ModelStore.hasHearing(context)) {
                    phase = Phase.Loading("Downloading speech recognition…")
                    hearingDownload = 0.0
                    try {
                        ModelStore.downloadHearing(context) { fraction ->
                            hearingDownload = fraction
                            phase = Phase.Loading("Downloading speech recognition… ${(fraction * 100).toInt()}%")
                        }
                    } finally { hearingDownload = null }
                }
                if (recognizer == null) {
                    phase = Phase.Loading("Loading speech recognition…")
                    recognizer = Recognizer(Hearing.parakeetFolder(context), threads = Threads.hearing)
                }
                if (linguist?.model != model) {
                    linguist?.close(); linguist = null  // one translation model in memory at a time
                    phase = Phase.Loading("Loading ${model.title}…")
                    linguist = Linguist(context, model, ModelStore.location(context, model), spoken, target)
                }
                if (voice == null) {
                    phase = Phase.Loading("Loading the voice…")
                    voice = PolyglotVoice.load(context)
                }
                voice?.language = target
                phase = Phase.Loading("Warming up…")
                linguist?.setLanguages(spoken, target)
                linguist?.warmUp()
            }
            phase = Phase.Ready
        } catch (e: Exception) {
            phase = Phase.Failed(e.message ?: e.toString())
        } finally {
            busy = false
        }
    }

    /** Fetch a model; progress shows in `downloads`. Use it straight away if none is in use yet. */
    fun download(model: TranslationModel) {
        if (model in downloads) return
        downloads[model] = 0.0
        viewModelScope.launch {
            try {
                ModelStore.download(context, model) { fraction -> downloads[model] = fraction }
                if (translationModel == null || !isDownloaded(translationModel!!)) use(model)
            } catch (e: Exception) {
                notice = "Couldn't download ${model.title}: ${e.message}"
            } finally {
                downloads.remove(model)
                storeChanges++
            }
        }
    }

    /** Switch the translation model; the old one leaves memory first. */
    fun use(model: TranslationModel) {
        if (busy || (model == translationModel && linguist != null)) return
        if (isLive) stop()
        translationModel = model
        prefs.edit().putString("translationModel", model.name).apply()
        linguist?.close(); linguist = null
        phase = Phase.Idle
        prepare()
    }

    fun delete(model: TranslationModel) {
        if (busy || model in downloads) return
        if (model == translationModel) {
            if (isLive) stop()
            linguist?.close(); linguist = null
            translationModel = null
            prefs.edit().remove("translationModel").apply()
            phase = Phase.ChoosingModel
        }
        ModelStore.delete(context, model)
        storeChanges++
    }

    // live

    /** The caller has the microphone permission. */
    fun start() {
        val recognizer = recognizer; val linguist = linguist; val voice = voice
        if (phase != Phase.Ready || busy || recognizer == null || linguist == null || voice == null) return
        linguist.forget()
        val pipeline = Pipeline(recognizer, linguist, voice, Bundled.vad(context))
        try {
            pipeline.start(Microphone(), audible = true) { event ->
                viewModelScope.launch { if (this@Session.pipeline === pipeline) apply(event) }
            }
        } catch (e: Exception) {
            pipeline.close()
            notice = "Couldn't open the audio: ${e.message}"
            return
        }
        this.pipeline = pipeline
        applyVoice()
        lineIDs.clear()
        notice = null
        phase = Phase.Live
        meter = viewModelScope.launch {
            while (true) {
                level = pipeline.level
                speaking = (pipeline.speaker?.backlog ?: 0.0) > 0.05
                delay(80)
            }
        }
    }

    fun stop() {
        val pipeline = pipeline ?: return
        this.pipeline = null
        meter?.cancel(); meter = null
        pipeline.stop()
        // The threads finish what they are in (a translation takes a second or two) before letting go.
        viewModelScope.launch(Dispatchers.Default) { pipeline.finish(); pipeline.close() }
        level = 0f; speaking = false; hearing = ""
        if (phase == Phase.Live) phase = Phase.Ready
    }

    /** Interpreting is foreground-only, as on the iPhone: leaving the app ends it. */
    fun paused() {
        if (isLive) {
            stop()
            notice = "Interpreter paused. Keep the app open and press Live to restart."
        }
    }

    fun clear() { lines.clear() }

    /** A piece of this session is waiting for its translation. */
    val translating get() = isLive && lines.any { it.translation == null && it.silence == null && it.id in lineIDs.values }

    private fun apply(event: PipelineEvent) {
        when (event) {
            is PipelineEvent.Hearing -> hearing = event.text
            is PipelineEvent.Committed -> {
                lineIDs[event.segment.index] = nextLineID
                lines += Line(nextLineID, event.segment.text, language = language(event.segment.text))
                nextLineID++
            }
            is PipelineEvent.Silent -> update(lineIDs[event.index] ?: return) {
                it.copy(silence = event.why, translation = event.translation,
                        language = if (event.why == Silence.UNDERSTOOD) target else it.language)
            }
            is PipelineEvent.Interpreted -> {
                val ids = event.indices.mapNotNull { lineIDs[it] }
                val first = ids.firstOrNull() ?: return
                // Merged pieces become one line, under the first.
                val merged = lines.filter { it.id in ids.drop(1) }.map { it.source }
                lines.removeAll { it.id in ids.drop(1) }
                update(first) {
                    val source = (listOf(it.source) + merged).joinToString(" ")
                    it.copy(source = source, language = language(source) ?: it.language, translation = event.translation,
                            lag = event.lags.maxOrNull(), pace = event.pace)
                }
            }
            is PipelineEvent.Failed -> {
                stop()
                phase = Phase.Failed(event.message)
                notice = event.message
            }
        }
    }

    /** A label, not a decision: short replies ("Igen") get no chip rather than a wrong one. */
    private fun language(text: String) = detector.guess(text)?.takeIf { it.confidence >= 0.6 }?.code

    private fun update(id: Int, change: (Line) -> Line) {
        val i = lines.indexOfLast { it.id == id }
        if (i >= 0) lines[i] = change(lines[i])
    }

    override fun onCleared() {
        stop()
        linguist?.close(); recognizer?.close(); voice?.close()
    }

    companion object {
        /** What the voice speaks well, in the order offered. */
        val trainedTargets = Polyphon.trained
        /** What it can be asked to speak beyond those: Parakeet's European languages, every one espeak-ng reads. */
        val untrainedTargets = Languages.names.keys.filter { it !in Polyphon.trained }.sortedBy { Languages.names[it] }
    }
}
