package com.snepssen.engine

/**
 * How many threads each model gets. Hearing and translating take turns at
 * the CPU (Pipeline), so each may use the fast cores while it works; four,
 * because a phone has four fast cores or more, and threads on its slow ones
 * would hold the fast ones back.
 */
object Threads {
    private val cores = Runtime.getRuntime().availableProcessors()
    val hearing get() = minOf(4, cores)
    val translating get() = minOf(4, cores)
}
