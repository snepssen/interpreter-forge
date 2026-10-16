package com.snepssen.hearing

import ai.onnxruntime.OrtEnvironment

/**
 * ONNX Runtime's one environment, its telemetry off. The manifest already
 * removes the provider that would start it; this is the second guard.
 */
object Ort {
    val env: OrtEnvironment by lazy { OrtEnvironment.getEnvironment().apply { runCatching { setTelemetry(false) } } }
}
