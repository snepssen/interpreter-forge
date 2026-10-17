package com.snepssen.interpreter

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * How big the conversation's text is, on top of the system's own font size:
 * for anyone who needs the translation in letters an arm's length away can
 * read. Remembered between launches.
 */
object TextSize {
    val steps = listOf(0.75f, 0.9f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f, 4f)

    fun label(scale: Float) = "${(scale * 100).roundToInt()}%"

    fun step(scale: Float, by: Int): Float {
        val here = steps.indexOfFirst { it >= scale - 0.001f }.takeIf { it >= 0 } ?: steps.lastIndex
        return steps[(here + by).coerceIn(0, steps.lastIndex)]
    }
}

/** A text style, scaled. Line height follows, or large lines would overlap. */
fun TextStyle.scaled(scale: Float) = copy(fontSize = fontSize * scale, lineHeight = lineHeight * scale)

/** Tt, then smaller, the size, and larger: in Settings and the tablet's panel. */
@Composable
fun TextSizeControl(session: Session, modifier: Modifier = Modifier) {
    val scale = session.textScale
    val index = TextSize.steps.indexOfFirst { it >= scale - 0.001f }.coerceAtLeast(0)
    Row(modifier.fillMaxWidth()
            // Adjustable to TalkBack (swipe up or down); the buttons stay for
            // Switch Access and Voice Access.
            .semantics {
                contentDescription = "Text size"
                stateDescription = TextSize.label(scale)
                progressBarRangeInfo = ProgressBarRangeInfo(index.toFloat(), 0f..TextSize.steps.lastIndex.toFloat(),
                                                            TextSize.steps.size - 2)
                setProgress { to -> session.stepTextScale(to.roundToInt() - index); true }
            },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Tt", Modifier.clearAndSetSemantics {}, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold),
             color = MaterialTheme.colorScheme.onSurfaceVariant)
        // In a narrow panel Tt says it alone.
        BoxWithConstraints(Modifier.weight(1f)) {
            if (maxWidth >= 72.dp) Text("Text size", Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodyLarge,
                                       maxLines = 1, softWrap = false)
        }
        IconButton(onClick = { session.stepTextScale(-1) }, enabled = scale > TextSize.steps.first()) {
            Icon(Minus, contentDescription = "Smaller text")
        }
        Text(TextSize.label(scale), Modifier.widthIn(min = 52.dp).clearAndSetSemantics {}, textAlign = TextAlign.Center,
             style = MaterialTheme.typography.bodyLarge)
        IconButton(onClick = { session.stepTextScale(1) }, enabled = scale < TextSize.steps.last()) {
            Icon(Icons.Filled.Add, contentDescription = "Larger text")
        }
    }
}

// Material's Remove and DarkMode, which the core icon set leaves out.
private fun icon(name: String, path: String) = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
    .addPath(addPathNodes(path), fill = SolidColor(Color.Black)).build()

val Minus = icon("Minus", "M19,13H5v-2h14v2z")
val Moon = icon("Moon", "M12,3c-4.97,0 -9,4.03 -9,9s4.03,9 9,9s9,-4.03 9,-9c0,-0.46 -0.04,-0.92 -0.1,-1.36" +
                        "c-0.98,1.37 -2.58,2.26 -4.4,2.26c-2.98,0 -5.4,-2.42 -5.4,-5.4c0,-1.81 0.89,-3.42 2.26,-4.4" +
                        "C12.92,3.04 12.46,3 12,3L12,3z")
