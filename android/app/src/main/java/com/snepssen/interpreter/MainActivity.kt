package com.snepssen.interpreter

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.snepssen.engine.Recording
import com.snepssen.engine.Wav
import java.io.File

class MainActivity : ComponentActivity() {
    private val session: Session by viewModels()

    private val microphone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) session.start()
        else session.notice = "Interpreter needs the microphone: allow it in Settings → Apps → Interpreter → Permissions, then press Live."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val context = LocalContext.current
            val dark = isSystemInDarkTheme()
            val colors = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            MaterialTheme(colorScheme = colors) {
                var settings by rememberSaveable { mutableStateOf(false) }
                var dark by rememberSaveable { mutableStateOf(false) }
                LaunchedEffect(session.isLive) { if (!session.isLive) dark = false }
                // Dark: the bars hidden and the backlight down, for an LCD's sake too.
                LaunchedEffect(dark) {
                    val bars = WindowCompat.getInsetsController(window, window.decorView)
                    bars.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    if (dark) bars.hide(WindowInsetsCompat.Type.systemBars()) else bars.show(WindowInsetsCompat.Type.systemBars())
                    window.attributes = window.attributes.apply {
                        screenBrightness = if (dark) 0.01f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    }
                }
                // Interpreting is foreground-only: the screen stays on while live,
                // and while models download (a sleeping phone may drop its Wi-Fi).
                val awake = session.isLive || session.downloads.isNotEmpty() || session.hearingDownload != null
                LaunchedEffect(awake) {
                    if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                BackHandler(enabled = settings || dark) { if (dark) dark = false else settings = false }
                if (dark) DarkScreen(session, roomy = LocalConfiguration.current.smallestScreenWidthDp >= 600) { dark = false }
                else Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                    if (settings) SettingsScreen(session) { settings = false }
                    else InterpreterScreen(session, onLive = ::live, onSettings = { settings = true }, onDark = { dark = true })
                }
            }
        }
    }

    private fun live() {
        // A debug build can be handed a recording to interpret as if it were
        // the microphone, a WAV in its files' demo folder (scripts/demo-app.sh).
        val recording = intent.getStringExtra("recording")?.takeIf { BuildConfig.DEBUG }
        if (recording != null) {
            runCatching { Recording(Wav.read16k(File(filesDir, "demo/$recording"))) }
                .onSuccess { session.start(it) }
                .onFailure { session.notice = "Couldn't read $recording: ${it.message}" }
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) session.start()
        else microphone.launch(Manifest.permission.RECORD_AUDIO)
    }

    /** Ctrl and minus or plus, on a tablet's keyboard: the text size. */
    override fun onKeyShortcut(keyCode: Int, event: KeyEvent): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_MINUS, KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> { session.stepTextScale(-1); true }
        KeyEvent.KEYCODE_PLUS, KeyEvent.KEYCODE_EQUALS, KeyEvent.KEYCODE_NUMPAD_ADD -> { session.stepTextScale(1); true }
        else -> super.onKeyShortcut(keyCode, event)
    }

    override fun onStart() {
        super.onStart()
        session.resumed()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) session.paused()
    }
}
