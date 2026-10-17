package com.snepssen.interpreter

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.snepssen.engine.Silence

/**
 * The screen dark while interpreting goes on: for a phone on the table, or a
 * pocket. Only the newest translation, dim, and Stop. A tap lights it again.
 */
@Composable
fun DarkScreen(session: Session, roomy: Boolean, onLight: () -> Unit) {
    val latest = session.lines.lastOrNull { it.silence == null && it.translation != null }
    Box(Modifier.fillMaxSize().background(Color.Black)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null,
                       onClickLabel = "Light the screen") { onLight() }) {
        Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
               verticalArrangement = Arrangement.spacedBy(28.dp)) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                // Shrinks to fit rather than run off the screen at a large text size.
                val size = (if (roomy) 34 else 22).sp * session.textScale
                BasicText(latest?.translation ?: "Listening",
                          style = TextStyle(color = Color(0xFF808080), fontWeight = FontWeight.Medium, textAlign = TextAlign.Center),
                          autoSize = TextAutoSize.StepBased(minFontSize = 12.sp, maxFontSize = size))
            }
            Box(Modifier.border(1.dp, Color(0xFF404040), CircleShape)
                    .clickable { session.stop() }
                    .semantics { contentDescription = "Stop interpreting" }
                    .padding(horizontal = 24.dp, vertical = 12.dp)) {
                Text("■  Stop", style = MaterialTheme.typography.titleMedium, color = Color(0xFF999999))
            }
            Text("Tap anywhere to light the screen", style = MaterialTheme.typography.labelSmall, color = Color(0xFF4D4D4D))
        }
    }
}
