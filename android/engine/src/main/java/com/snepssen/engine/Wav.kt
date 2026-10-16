package com.snepssen.engine

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

object Wav {
    /** A 16-bit mono WAV at any rate, to 16 kHz floats, for speech recognition. */
    fun read16k(file: File): FloatArray {
        val bytes = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        val rate = bytes.getInt(24)
        var pos = 12
        while (pos + 8 <= bytes.limit()) {
            val id = String(ByteArray(4) { bytes.get(pos + it) }); val size = bytes.getInt(pos + 4)
            if (id == "data") break
            pos += 8 + size
        }
        val n = bytes.getInt(pos + 4) / 2
        val src = FloatArray(n) { bytes.getShort(pos + 8 + it * 2) / 32768f }
        val step = rate / 16_000.0
        return FloatArray((n / step).toInt()) { k -> val x = k * step; val i = x.toInt(); val f = (x - i).toFloat()
            src[i] + (src[minOf(i + 1, n - 1)] - src[i]) * f }
    }
}
