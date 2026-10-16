package com.snepssen.interpreter

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.snepssen.core.Languages
import com.snepssen.engine.Silence
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The conversation screen. Mostly it isn't looked at: the interpreter is in
 * the headphones. So it answers three things at a glance (is it on, what is
 * it doing, what was just said) and keeps everything else one tap away.
 */
@Composable
fun InterpreterScreen(session: Session, onLive: () -> Unit, onSettings: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            LanguageMenu(session, locked = session.isLive || session.busy, modifier = Modifier.weight(1f, fill = false))
            IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings") }
        }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { Content(session) }
        if (session.phase != Session.Phase.ChoosingModel) {
            HorizontalDivider()
            Controls(session, onLive)
        }
    }
}

@Composable
private fun Content(session: Session) {
    when (val phase = session.phase) {
        Session.Phase.ChoosingModel -> ModelPicker(session)
        Session.Phase.Idle -> Message(if (session.busy) "Getting ready" else "Starting…") { CircularProgressIndicator() }
        is Session.Phase.Loading -> Message(phase.what) { CircularProgressIndicator() }
        is Session.Phase.Failed -> Message("Interpreter needs attention", detail = phase.why, warning = true) {
            Button(onClick = { session.prepare() }, enabled = !session.busy) { Text("Try again") }
        }
        Session.Phase.Ready, Session.Phase.Live -> {
            val visible = session.lines.filter {
                session.showOwnLanguage || (it.silence != Silence.UNDERSTOOD && it.silence != Silence.ECHO)
            }
            when {
                visible.isEmpty() && session.isLive -> Message("Translations appear here as people speak.")
                visible.isEmpty() -> Message("Ready to interpret", detail = readyDetail(session))
                else -> Transcript(visible, session.isLive)
            }
        }
    }
}

private fun readyDetail(session: Session): String {
    val into = session.languageName(session.target)
    if (session.spoken.isEmpty()) return "Put your headphones in. Other languages are spoken to you in $into."
    val verb = if (session.spoken.size == 1) "is" else "are"
    return "${Languages.list(session.spoken)} $verb spoken to you in $into; other languages are skipped."
}

@Composable
private fun Message(title: String, detail: String? = null, warning: Boolean = false, extra: @Composable () -> Unit = {}) {
    Column(Modifier.widthIn(max = 420.dp).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (warning) Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(40.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (detail != null) Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        Box(Modifier.padding(top = 6.dp)) { extra() }
    }
}

@Composable
private fun Transcript(lines: List<Session.Line>, isLive: Boolean) {
    val state = rememberLazyListState()
    // The newest piece meant for the listener stays large, even when their own
    // language was spoken after it: that is the line to catch up on.
    val latest = lines.lastOrNull { it.silence == null || it.silence == Silence.UNCLEAR }?.id
    LaunchedEffect(lines.size, lines.lastOrNull()) { if (lines.isNotEmpty()) state.animateScrollToItem(lines.size - 1) }
    LazyColumn(Modifier.fillMaxSize(), state = state, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
               verticalArrangement = Arrangement.spacedBy(16.dp)) {
        items(lines, key = { it.id }) { LineView(it, prominent = it.id == latest, isLive = isLive) }
    }
}

/**
 * One piece of conversation. The newest translation is large, with what was
 * said under it; older lines are plain, lines already in the listener's
 * language quieter still.
 */
@Composable
private fun LineView(line: Session.Line, prominent: Boolean, isLive: Boolean) {
    val quiet = MaterialTheme.colorScheme.onSurfaceVariant
    val faint = quiet.copy(alpha = 0.6f)
    val type = MaterialTheme.typography
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        LanguageChip(line.language)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            when (line.silence) {
                Silence.UNDERSTOOD, Silence.ECHO -> Text(line.source, fontStyle = FontStyle.Italic, color = quiet)
                Silence.LANGUAGE -> {
                    Text(line.source, color = faint)
                    Text("Skipped: not one of your languages", style = type.labelSmall, color = faint)
                }
                Silence.UNCLEAR -> {
                    Text("? " + (line.translation ?: "Please repeat this piece."),
                         style = if (prominent) type.titleMedium else type.bodyLarge, color = Color(0xFFE08A00))
                    Text(line.source, style = type.bodyMedium, color = quiet)
                }
                null -> if (line.translation != null) {
                    Text(line.translation, style = if (prominent) type.headlineSmall.copy(fontWeight = FontWeight.SemiBold) else type.bodyLarge)
                    if (prominent) Text(line.source, style = type.bodyMedium, color = quiet)
                } else {
                    Text(line.source, style = if (prominent) type.titleMedium else type.bodyLarge, color = quiet)
                    Text(if (isLive) "Translating…" else "Stopped before translation", style = type.labelSmall, color = faint)
                }
            }
        }
    }
}

/** Who spoke a line: "PL", "HU". Blank when the detector wasn't sure. */
@Composable
private fun LanguageChip(code: String?) {
    Box(Modifier.padding(top = 2.dp).size(width = 30.dp, height = 20.dp)
            .background(if (code == null) Color.Transparent else MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(5.dp))
            .semantics { contentDescription = code?.let { Languages.names[it] ?: it } ?: "" },
        contentAlignment = Alignment.Center) {
        Text(code?.uppercase() ?: "", style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
             color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** What is spoken here and what it becomes: "Any language → Hungarian". */
@Composable
private fun LanguageMenu(session: Session, locked: Boolean, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf(false) }
    val into = session.languageName(session.target)
    val summary = when {
        session.spoken.isEmpty() -> "Any language"
        session.spoken.size > 2 -> "${session.spoken.size} languages"
        else -> Languages.list(session.spoken)
    }
    Box(modifier) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier.clickable(enabled = !locked) { open = true }.alpha(if (locked) 0.6f else 1f)) {
            Text("$summary → $into" + if (locked) "" else "  ▾", style = MaterialTheme.typography.labelLarge,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Text("Into", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            for (code in session.targetChoices) {
                DropdownMenuItem(
                    text = { Text(session.languageName(code) + if (session.isTrained(code)) "" else " (untrained)") },
                    leadingIcon = { Text(if (code == session.target) "✓" else " ") },
                    onClick = { session.chooseTarget(code); open = false })
            }
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Any language") },
                             leadingIcon = { Text(if (session.spoken.isEmpty()) "✓" else " ") },
                             onClick = { session.chooseSpoken(emptyList()) })
            Text("Only these languages", style = MaterialTheme.typography.labelMedium,
                 modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            for ((code, name) in Languages.names.filterKeys { it != session.target }.toList().sortedBy { it.second }) {
                val on = code in session.spoken
                DropdownMenuItem(
                    text = { Text(name) },
                    leadingIcon = { Checkbox(checked = on, onCheckedChange = null) },
                    onClick = { session.chooseSpoken(if (on) session.spoken - code else session.spoken + code) })
            }
        }
    }
}

@Composable
private fun Controls(session: Session, onLive: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 10.dp),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (session.isLive) {
            Text("👂  " + session.hearing.ifEmpty { "Waiting for speech" }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                 style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxWidth(),
                 color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (session.hearing.isEmpty()) 0.6f else 1f))
        }
        session.notice?.let {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Warning, null, tint = Color(0xFFE08A00), modifier = Modifier.size(18.dp))
                Text(it, style = MaterialTheme.typography.bodyMedium)
            }
        }
        LiveButton(session, onLive)
        Text(status(session), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
             maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** One status for the whole screen: what the interpreter is doing. */
private fun status(session: Session): String = when (session.phase) {
    Session.Phase.Live -> when {
        session.speaking -> session.lines.lastOrNull { it.lag != null }?.lag?.let { "Speaking · %.1f s behind".format(it) } ?: "Speaking"
        session.translating -> "Translating…"
        else -> "Listening"
    }
    Session.Phase.Ready -> if (session.busy) "Starting…" else session.translationModel?.title ?: ""
    is Session.Phase.Failed -> "Stopped"
    else -> " "
}

/**
 * Start and stop: one large target, with the microphone level as a ring
 * around it so it's clear at a glance that sound is coming in.
 */
@Composable
private fun LiveButton(session: Session, onLive: () -> Unit) {
    val enabled = !session.busy && (session.phase == Session.Phase.Ready || session.isLive)
    val level by animateFloatAsState(if (session.isLive) min(1f, sqrt(session.level) * 3) else 0f, label = "level")
    val accent = MaterialTheme.colorScheme.primary
    Box(Modifier.padding(10.dp).size(84.dp), contentAlignment = Alignment.Center) {
        if (session.isLive) {
            Box(Modifier.matchParentSize().scale(1.06f + 0.22f * level).border(5.dp, accent.copy(alpha = 0.45f), CircleShape))
        }
        Box(Modifier.matchParentSize().alpha(if (enabled) 1f else 0.4f)
                .background(if (session.isLive) Color(0xFFE5393A) else accent, CircleShape)
                .clickable(enabled = enabled) { if (session.isLive) session.stop() else onLive() }
                .semantics { contentDescription = if (session.isLive) "Stop interpreting" else "Start interpreting" },
            contentAlignment = Alignment.Center) {
            if (session.isLive) Box(Modifier.size(26.dp).background(Color.White, RoundedCornerShape(4.dp)))
            else Text("Live", color = Color.White, style = MaterialTheme.typography.titleMedium)
        }
    }
    Spacer(Modifier.height(0.dp))
}
