package com.snepssen.interpreter

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
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
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
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
                // Interpreting is foreground-only: the screen stays on while live.
                LaunchedEffect(session.isLive) {
                    if (session.isLive) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                BackHandler(enabled = settings) { settings = false }
                Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                    if (settings) SettingsScreen(session) { settings = false }
                    else InterpreterScreen(session, onLive = ::live, onSettings = { settings = true })
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

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) session.paused()
    }
}
