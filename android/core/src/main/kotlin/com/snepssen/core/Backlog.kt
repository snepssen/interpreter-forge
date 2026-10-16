package com.snepssen.core

/**
 * What a human interpreter does when falling behind: say it faster, and, if the
 * listener chose to keep up rather than hear all, say less. The backlog is how
 * long a piece would wait behind the interpreter still speaking.
 */
data class Backlog(
    val briefAfter: Double = 1.5,  // seconds of backlog before translating for the gist
    val fasterAfter: Double = 1.0,  // seconds of backlog before speeding up
    val pacePerSecond: Double = 0.1,  // extra pace per second of backlog beyond that
    val maxPace: Double = 1.3,
) {
    fun brief(backlog: Double) = backlog >= briefAfter
    fun pace(backlog: Double) = if (backlog <= fasterAfter) 1.0 else minOf(maxPace, 1 + pacePerSecond * (backlog - fasterAfter))
}
