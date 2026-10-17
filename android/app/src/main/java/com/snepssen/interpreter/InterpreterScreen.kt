package com.snepssen.interpreter

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material3.Slider
import androidx.compose.material3.VerticalDivider
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.min
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
fun InterpreterScreen(session: Session, onLive: () -> Unit, onSettings: () -> Unit, onDark: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // A tablet either way up (not a phone on its side): bigger type and a bigger button.
        val roomy = min(maxWidth, maxHeight) >= 600.dp
        // Landscape puts the controls in a panel beside the conversation: on a
        // tablet for the room, on a phone on its side because stacked would
        // leave the conversation a sliver. Portrait keeps the stacked layout.
        val wide = maxWidth >= 600.dp && maxWidth > maxHeight && session.phase != Session.Phase.ChoosingModel
        val panel = max(280.dp, min(400.dp, maxWidth * 0.34f))
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) { Content(session, roomy) }
                VerticalDivider()
                SidePanel(session, onLive, onSettings, onDark, Modifier.width(panel))
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    LanguageMenu(session, locked = session.isLive || session.busy, modifier = Modifier.weight(1f, fill = false))
                    Row { BarButtons(session, onSettings, onDark) }
                }
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { Content(session, roomy) }
                if (session.phase != Session.Phase.ChoosingModel) {
                    HorizontalDivider()
                    Controls(session, onLive, roomy)
                }
            }
        }
    }
}

@Composable
private fun BarButtons(session: Session, onSettings: () -> Unit, onDark: () -> Unit) {
    if (session.isLive) IconButton(onClick = onDark) { Icon(Moon, contentDescription = "Darken the screen") }
    IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings") }
}

/**
 * Everything the stacked layout has above and below the conversation, beside
 * it instead, with room to spare: the hearing line runs longer, the button is
 * bigger, and the voice's quick settings and the text size are at hand.
 */
@Composable
private fun SidePanel(session: Session, onLive: () -> Unit, onSettings: () -> Unit, onDark: () -> Unit, modifier: Modifier) {
    val card = MaterialTheme.colorScheme.surface
    BoxWithConstraints(modifier.fillMaxHeight().background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))) {
        // A short window (a large phone on its side) scrolls rather than squeezes.
        val tall = maxHeight >= 600.dp
        Column(Modifier.verticalScroll(rememberScrollState()).heightIn(min = maxHeight)
                   .padding(horizontal = 24.dp, vertical = 16.dp),
               verticalArrangement = Arrangement.SpaceBetween) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                LanguageMenu(session, locked = session.isLive || session.busy, modifier = Modifier.weight(1f))
                BarButtons(session, onSettings, onDark)
            }
            Column(Modifier.padding(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                if (session.isLive) {
                    Column(Modifier.fillMaxWidth().background(card, RoundedCornerShape(14.dp)).padding(16.dp)
                               .semantics(mergeDescendants = true) {},
                           verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("👂  Hearing", style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                             color = MaterialTheme.colorScheme.onSurfaceVariant)
                        // Short of room, it stays small enough to leave Stop in sight.
                        Text(session.hearing.ifEmpty { "Waiting for speech" }, maxLines = if (tall) 6 else 2,
                             overflow = TextOverflow.Ellipsis,
                             style = MaterialTheme.typography.titleMedium.scaled(min(session.textScale, if (tall) 2f else 1.25f)),
                             color = if (session.hearing.isEmpty()) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                                     else MaterialTheme.colorScheme.onSurface)
                    }
                }
                session.notice?.let { Notice(it) }
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    LiveButton(session, onLive, size = if (tall) 128.dp else 96.dp)
                    Text(status(session), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                         maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Column(Modifier.fillMaxWidth().background(card, RoundedCornerShape(14.dp)).padding(horizontal = 16.dp, vertical = 8.dp)) {
                TextSizeControl(session)
                Toggle("Captions only", session.captionsOnly) { session.chooseCaptionsOnly(it) }
                Text("Volume", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(top = 8.dp),
                     color = if (session.captionsOnly) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                Slider(value = session.voiceVolume, onValueChange = { session.chooseVolume(it) }, enabled = !session.captionsOnly,
                       modifier = Modifier.semantics { contentDescription = "Volume" })
            }
        }
    }
}

@Composable
private fun Content(session: Session, roomy: Boolean) {
    when (val phase = session.phase) {
        Session.Phase.ChoosingModel -> ModelPicker(session)
        Session.Phase.Idle -> Message(if (session.busy) "Getting ready" else "Starting…", roomy = roomy) { CircularProgressIndicator() }
        is Session.Phase.Loading -> Message(phase.what, roomy = roomy) { CircularProgressIndicator() }
        is Session.Phase.Failed -> Message("Interpreter needs attention", detail = phase.why, warning = true, roomy = roomy) {
            Button(onClick = { session.prepare() }, enabled = !session.busy) { Text("Try again") }
        }
        Session.Phase.Ready, Session.Phase.Live -> {
            val visible = session.lines.filter {
                session.showOwnLanguage || (it.silence != Silence.UNDERSTOOD && it.silence != Silence.ECHO)
            }
            when {
                visible.isEmpty() && session.isLive -> Message("Translations appear here as people speak.", roomy = roomy)
                visible.isEmpty() -> Message("Ready to interpret", detail = readyDetail(session), roomy = roomy)
                else -> Transcript(visible, session.isLive, roomy, session.textScale)
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
private fun Message(title: String, detail: String? = null, warning: Boolean = false, roomy: Boolean = false,
                    extra: @Composable () -> Unit = {}) {
    Column(Modifier.widthIn(max = if (roomy) 520.dp else 420.dp).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (warning) Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(40.dp))
        Text(title, style = if (roomy) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
             textAlign = TextAlign.Center)
        if (detail != null) Text(detail, style = if (roomy) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.bodyMedium,
                                 color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        Box(Modifier.padding(top = 6.dp)) { extra() }
    }
}

@Composable
private fun Transcript(lines: List<Session.Line>, isLive: Boolean, roomy: Boolean, scale: Float) {
    val state = rememberLazyListState()
    // The newest piece meant for the listener stays large, even when their own
    // language was spoken after it: that is the line to catch up on.
    val latest = lines.lastOrNull { it.silence == null || it.silence == Silence.UNCLEAR }?.id
    LaunchedEffect(lines.size, lines.lastOrNull(), scale) { if (lines.isNotEmpty()) state.animateScrollToItem(lines.size - 1) }
    LazyColumn(Modifier.fillMaxSize(), state = state, contentPadding = PaddingValues(if (roomy) 28.dp else 16.dp),
               horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        items(lines, key = { it.id }) {
            Box(Modifier.widthIn(max = if (roomy) 860.dp else 720.dp).fillMaxWidth()) {
                LineView(it, prominent = it.id == latest, isLive = isLive, roomy = roomy, scale = scale)
            }
        }
    }
}

/**
 * One piece of conversation. The newest translation is large, with what was
 * said under it; older lines are plain, lines already in the listener's
 * language quieter still. A tablet's type is a step up; the chosen text size
 * multiplies all of it, on top of the system's font size.
 */
@Composable
private fun LineView(line: Session.Line, prominent: Boolean, isLive: Boolean, roomy: Boolean, scale: Float) {
    val quiet = MaterialTheme.colorScheme.onSurfaceVariant
    val faint = quiet.copy(alpha = 0.6f)
    val type = MaterialTheme.typography
    val lead = (if (roomy) type.headlineMedium else type.headlineSmall).copy(fontWeight = FontWeight.SemiBold).scaled(scale)
    val raised = (if (roomy) type.headlineSmall else type.titleMedium).scaled(scale)
    val plain = (if (roomy) type.titleLarge else type.bodyLarge).scaled(scale)
    val under = (if (roomy) type.bodyLarge else type.bodyMedium).scaled(scale)
    val note = type.labelSmall.scaled(scale)
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp * min(scale, 2f))) {
        LanguageChip(line.language, scale)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            when (line.silence) {
                Silence.UNDERSTOOD, Silence.ECHO -> Text(line.source, style = plain, fontStyle = FontStyle.Italic, color = quiet)
                Silence.LANGUAGE -> {
                    Text(line.source, style = plain, color = faint)
                    Text("Skipped: not one of your languages", style = note, color = faint)
                }
                Silence.UNCLEAR -> {
                    Text("? " + (line.translation ?: "Please repeat this piece."),
                         style = if (prominent) raised else plain, color = Color(0xFFE08A00))
                    Text(line.source, style = under, color = quiet)
                }
                null -> if (line.translation != null) {
                    Text(line.translation, style = if (prominent) lead else plain)
                    if (prominent) Text(line.source, style = under, color = quiet)
                } else {
                    Text(line.source, style = if (prominent) raised else plain, color = quiet)
                    Text(if (isLive) "Translating…" else "Stopped before translation", style = note, color = faint)
                }
            }
        }
    }
}

/**
 * Who spoke a line: "PL", "HU". Blank when the detector wasn't sure. Grows
 * more gently than the text beside it: a label, not the content.
 */
@Composable
private fun LanguageChip(code: String?, scale: Float) {
    val grow = sqrt(scale)
    Box(Modifier.padding(top = 2.dp * grow).size(width = 30.dp * grow, height = 20.dp * grow)
            .background(if (code == null) Color.Transparent else MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(5.dp))
            .semantics { contentDescription = code?.let { Languages.names[it] ?: it } ?: "" },
        contentAlignment = Alignment.Center) {
        Text(code?.uppercase() ?: "", style = MaterialTheme.typography.labelSmall.scaled(grow), fontFamily = FontFamily.Monospace,
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
private fun Controls(session: Session, onLive: () -> Unit, roomy: Boolean) {
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 10.dp),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (session.isLive) {
            Text("👂  " + session.hearing.ifEmpty { "Waiting for speech" }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                 style = MaterialTheme.typography.bodyMedium.scaled(min(session.textScale, 2f)),
                 modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth(),
                 color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (session.hearing.isEmpty()) 0.6f else 1f))
        }
        session.notice?.let { Notice(it, Modifier.widthIn(max = 720.dp)) }
        LiveButton(session, onLive, size = if (roomy) 100.dp else 84.dp)
        Text(status(session), style = if (roomy) MaterialTheme.typography.bodyMedium else MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
             maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun Notice(text: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Filled.Warning, null, tint = Color(0xFFE08A00), modifier = Modifier.size(18.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
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
private fun LiveButton(session: Session, onLive: () -> Unit, size: Dp) {
    val enabled = !session.busy && (session.phase == Session.Phase.Ready || session.isLive)
    val level by animateFloatAsState(if (session.isLive) min(1f, sqrt(session.level) * 3) else 0f, label = "level")
    val accent = MaterialTheme.colorScheme.primary
    Box(Modifier.padding(10.dp).size(size), contentAlignment = Alignment.Center) {
        if (session.isLive) {
            Box(Modifier.matchParentSize().scale(1.06f + 0.22f * level).border(5.dp, accent.copy(alpha = 0.45f), CircleShape))
        }
        Box(Modifier.matchParentSize().alpha(if (enabled) 1f else 0.4f)
                .background(if (session.isLive) Color(0xFFE5393A) else accent, CircleShape)
                .clickable(enabled = enabled) { if (session.isLive) session.stop() else onLive() }
                .semantics { contentDescription = if (session.isLive) "Stop interpreting" else "Start interpreting" },
            contentAlignment = Alignment.Center) {
            if (session.isLive) Box(Modifier.size(size * 0.31f).background(Color.White, RoundedCornerShape(size * 0.05f)))
            else Text("Live", color = Color.White,
                      style = if (size > 84.dp) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium)
        }
    }
    Spacer(Modifier.height(0.dp))
}
