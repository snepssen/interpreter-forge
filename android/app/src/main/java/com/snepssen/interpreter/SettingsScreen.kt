package com.snepssen.interpreter

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.snepssen.core.Languages
import com.snepssen.engine.TranslationModel

/**
 * The first launch: which translator to download. TranslateGemma unless the
 * phone can't run it; EuroLLM only then; and if neither fits, an honest
 * "this phone can't".
 */
@Composable
fun ModelPicker(session: Session) {
    val recommended = session.recommended
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Choose a translator", style = MaterialTheme.typography.headlineSmall)
            if (recommended == null) {
                Text("This phone doesn't have the memory to translate on the device: even the smallest model needs 4 GB. " +
                     "Interpreter keeps everything on the phone, so it can't run here.",
                     color = MaterialTheme.colorScheme.error)
            } else {
                Text("Everything runs on this phone: speech, translation and the voice. The translator is a one-time " +
                     "download; speech recognition (${size(session, 670_576_886)}) comes with it. Use Wi-Fi.",
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            for (model in TranslationModel.entries) ModelCard(session, model, recommended == model)
        }
    }
}

@Composable
private fun ModelCard(session: Session, model: TranslationModel, recommended: Boolean) {
    val fits = session.fits(model)
    val downloaded = session.storeChanges.let { session.isDownloaded(model) }
    val progress = session.downloads[model]
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.padding(16.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(model.title, style = MaterialTheme.typography.titleMedium)
                    Text(model.tagline + if (recommended) " · Recommended for this phone" else "",
                         style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
                when {
                    progress != null -> Text("${(progress * 100).toInt()}%", style = MaterialTheme.typography.labelLarge)
                    model == session.translationModel && downloaded -> Text("In use", color = MaterialTheme.colorScheme.primary)
                    downloaded -> TextButton(onClick = { session.use(model) }, enabled = fits && !session.busy) { Text("Use") }
                    else -> Button(onClick = { session.download(model) }, enabled = fits) { Text("Get · ${size(session, model.file.size)}") }
                }
            }
            if (progress != null) LinearProgressIndicator(progress = { progress.toFloat() }, modifier = Modifier.fillMaxWidth())
            Text(model.summary, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!fits) Text("This phone has too little memory for it.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error)
            if (downloaded && progress == null) {
                TextButton(onClick = { session.delete(model) }, enabled = !session.busy && !session.isLive,
                           modifier = Modifier.padding(0.dp)) { Text("Delete from this phone") }
            }
        }
    }
}

@Composable
private fun size(session: Session, bytes: Long) = Formatter.formatShortFileSize(LocalContext.current, bytes)

/** Everything that isn't the conversation: models, the voice, the transcript. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(session: Session, onDone: () -> Unit) {
    val locked = session.isLive || session.busy
    Scaffold(topBar = {
        TopAppBar(title = { Text("Settings") }, actions = { TextButton(onClick = onDone) { Text("Done") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
               verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Header("Translator")
            for (model in TranslationModel.entries) ModelCard(session, model, session.recommended == model)
            Footer("One model is loaded at a time. TranslateGemma translates best; EuroLLM is for phones that can't run it.")

            Header("Language")
            for (code in session.targetChoices) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    RadioButton(selected = code == session.target, onClick = { session.chooseTarget(code) }, enabled = !locked)
                    Text(session.languageName(code) + if (session.isTrained(code)) "" else " (untrained)")
                }
            }
            Toggle("Untrained languages", session.untrainedLanguages, enabled = !locked) { session.chooseUntrained(it) }
            Footer("Interpret into one of the languages the voice was trained on: ${Languages.list(Session.trainedTargets)}. " +
                   "Untrained languages offers the other European languages too; the voice reads them without its " +
                   "corrections, so expect an accent and some wrong sounds.")

            Header("Voice")
            Text("Volume", style = MaterialTheme.typography.bodyLarge)
            Slider(value = session.voiceVolume, onValueChange = { session.chooseVolume(it) }, enabled = !session.captionsOnly)
            Toggle("Captions only", session.captionsOnly) { session.chooseCaptionsOnly(it) }
            Toggle("Summarise to keep up", false, enabled = false) {}
            Footer("Captions only shows translations without speaking them: for a phone on the table when nobody has " +
                   "headphones. Summarise to keep up says only the gist when the interpreter falls behind; it needs a " +
                   "model that takes instructions, and neither translator on Android does: everything is translated " +
                   "in full and the voice only speeds up a little.")

            Header("Conversation")
            Toggle("Show lines already in ${session.languageName(session.target)}", session.showOwnLanguage) { session.chooseShowOwnLanguage(it) }
            OutlinedButton(onClick = { session.clear() }, enabled = session.lines.isNotEmpty() && !session.isLive) {
                Text("Clear conversation")
            }
            Footer("Speech, translations and models stay on this phone.")
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Footer("The voice: snepssen, a Piper voice reading through espeak-ng (GPL-3.0). Speech recognition: Parakeet Ultra " +
                   "(moondream, CC-BY-4.0). Translation: TranslateGemma (Google, Gemma terms) or EuroLLM " +
                   "(UTTER, Apache-2.0), on llama.cpp (MIT).")
        }
    }
}

@Composable
private fun Header(text: String) =
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
         modifier = Modifier.padding(top = 16.dp))

@Composable
private fun Footer(text: String) =
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Toggle(label: String, on: Boolean, enabled: Boolean = true, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked = on, onCheckedChange = change, enabled = enabled)
    }
}
