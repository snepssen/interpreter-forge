package com.snepssen.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The Kotlin core held to the same cases as the iPhone app's tccheck, which
 * holds the Swift core to the Python one: same inputs, same answers.
 */
class ParityTest {
    /** One word per `step` seconds, each lasting 0.3 s. */
    private fun words(text: String, start: Double = 0.0, step: Double = 0.4) =
        text.split(" ").mapIndexed { i, t -> Word(t, start + i * step, start + i * step + 0.3) }

    private fun segmenter(config: SegmenterConfig = SegmenterConfig(), judge: (suspend (String) -> Boolean)? = null) =
        Segmenter(config.copy(adapt = false), judge)

    /** Complete when the text ends in one of `endings`; keeps what it was asked. */
    private class FakeJudge(vararg val endings: String) {
        val asked = mutableListOf<String>()
        suspend operator fun invoke(text: String): Boolean {
            asked += text
            val trimmed = text.trim('.', ',')
            return endings.any { trimmed.endsWith(it) }
        }
    }

    private fun List<Segment>.texts() = map { it.text }

    // segmenter

    @Test fun fullStopAtWindowEndIsNotTrusted() = runBlocking {
        val s = segmenter(); val hyp = words("Ich wollte nur sagen.")
        assertTrue(s.step(2.0, hyp, 0.0).isEmpty() && s.step(2.5, hyp, 0.0).isEmpty())
    }

    @Test fun sentenceEndWithStableSpeechAfterItCommits() = runBlocking {
        val s = segmenter(); val hyp = words("Ich wollte nur sagen. Dass wir")
        val first = s.step(2.5, hyp, 0.0); val second = s.step(3.0, hyp, 0.0)
        assertTrue(first.isEmpty())
        assertEquals(listOf("Ich wollte nur sagen."), second.texts())
        assertEquals("sentence", second.first().reason)
        assertEquals(hyp[3].end, s.mark, 1e-12)
        assertEquals(listOf("Dass", "wir"), s.pending.map { it.text })
    }

    @Test fun fullStopThatMovesIsNotStable() = runBlocking {
        val s = segmenter()
        s.step(2.5, words("Ich wollte nur sagen. Dass wir"), 0.0)
        assertTrue(s.step(3.0, words("Ich wollte nur sagen, dass wir morgen"), 0.0).isEmpty())
    }

    @Test fun hesitationAfterAFinalFullStopDoesNotConfirmIt() = runBlocking {
        val s = segmenter(); val hyp = words("Ich wollte sagen, dass wir.")
        s.step(2.0, hyp, 0.0)
        assertTrue(s.step(3.0, hyp, 1.1).isEmpty())
    }

    @Test fun caseAndCommaFlickerStillCountsAsStable() = runBlocking {
        val s = segmenter()
        s.step(2.5, words("ich wollte nur sagen. Dass wir"), 0.0)
        assertEquals(listOf("Ich wollte nur, sagen."), s.step(3.0, words("Ich wollte nur, sagen. dass wir"), 0.0).texts())
    }

    @Test fun midSentenceHesitationWaits() = runBlocking {
        val s = segmenter(); val hyp = words("Also ich wollte eigentlich")
        s.step(2.0, hyp, 0.5)
        assertTrue(s.step(2.5, hyp, 1.0).isEmpty())
    }

    @Test fun longPauseCommitsEverything() = runBlocking {
        val s = segmenter()
        val out = s.step(4.0, words("Also ich wollte eigentlich"), 1.5)
        assertEquals(listOf("Also ich wollte eigentlich"), out.texts())
        assertEquals("pause", out.first().reason)
        assertTrue(s.pending.isEmpty())
    }

    @Test fun shortSentenceWaitsToJoinTheNext() = runBlocking {
        val s = segmenter(); val short = words("Ja. Das ist")
        s.step(1.5, short, 0.0)
        val waited = s.step(2.0, short, 0.0).isEmpty()
        val hyp = words("Ja. Das ist gut. Und dann")
        s.step(2.5, hyp, 0.0)
        val out = s.step(3.0, hyp, 0.0)
        assertTrue(waited)
        assertEquals(listOf("Ja. Das ist gut."), out.texts())
    }

    @Test fun earlierSentenceEndCommitsWhenTheLatestIsUnconfirmed() = runBlocking {
        val s = segmenter(); val hyp = words("Das ist ein Satz. Und noch einer.")
        s.step(3.0, hyp, 0.0)
        assertEquals(listOf("Das ist ein Satz."), s.step(3.5, hyp, 0.0).texts())
    }

    @Test fun runOnSpeechIsCutAtTheLastComma() = runBlocking {
        val s = segmenter(SegmenterConfig(softSegment = 4.0))
        val hyp = words("wir haben das gemacht, weil es nötig war, und dann haben wir noch")
        s.step(5.0, hyp, 0.0)
        val out = s.step(5.5, hyp, 0.0)
        assertEquals(listOf("wir haben das gemacht, weil es nötig war,"), out.texts())
        assertEquals("clause", out.first().reason)
    }

    @Test fun commaTooEarlyToLeaveARealPieceIsSkipped() = runBlocking {
        val s = segmenter(SegmenterConfig(softSegment = 4.0, maxSegment = 10.0, hardSegment = 15.0))
        val hyp = words("Ja, also wir haben das gemacht weil es nötig war und dann haben wir noch")
        s.step(5.0, hyp, 0.0)
        assertTrue(s.step(5.5, hyp, 0.0).isEmpty())
    }

    @Test fun runOnSpeechWithoutCommasIsCutAtTheWidestGap() = runBlocking {
        val s = segmenter(SegmenterConfig(softSegment = 3.0, maxSegment = 4.0))
        val hyp = words("eins zwei drei vier fünf sechs sieben") + words("acht neun zehn elf zwölf", start = 3.6)
        s.step(6.0, hyp, 0.0)
        val out = s.step(6.5, hyp, 0.0)
        assertEquals(listOf("eins zwei drei vier fünf sechs sieben"), out.texts())
        assertEquals("force", out.first().reason)
    }

    @Test fun leftContextWordsAreDropped() {
        val s = segmenter(); s.mark = 1.0
        assertEquals(listOf("neu"), s.newWords(listOf(Word("alt.", 0.6, 0.95), Word("neu", 1.1, 1.4))).map { it.text })
    }

    @Test fun nextWordSurvivesTimingDriftCommittedWordDoesNotRepeat() = runBlocking {
        val s = segmenter(); val hyp = words("Das ist ein Satz. Der nächste")
        s.step(2.5, hyp, 0.0); s.step(3.0, hyp, 0.0)
        val drifted = listOf(Word("Satz.", 1.25, 1.45), Word("Der", 1.42, 1.6), Word("nächste", 1.7, 2.0))
        assertEquals(listOf("Der", "nächste"), s.newWords(drifted).map { it.text })
    }

    @Test fun pausesStretchForAHesitantSpeaker() = runBlocking {
        val s = Segmenter(SegmenterConfig())
        val base = s.longPauseThreshold()
        for (i in 0 until 10) s.step(0.0, words("ein sehr langsamer Satz.", start = i * 10.0, step = 1.2), 9.0)
        assertTrue(base < s.longPauseThreshold() && s.longPauseThreshold() <= s.config.maxLongPause)
    }

    @Test fun committedWordReheardDifferentlyIsNotRepeated() = runBlocking {
        val s = segmenter()
        s.step(3.0, words("Meldet sich bitte bei mir"), 2.0)
        val reheard = listOf(Word("Mehr.", s.mark - 0.25, s.mark + 0.05), Word("Danke.", s.mark + 1.5, s.mark + 1.9))
        assertEquals(listOf("Danke."), s.newWords(reheard).map { it.text })
    }

    @Test fun judgeCommitsACompleteThoughtAtAShortPause() = runBlocking {
        val judge = FakeJudge("anfangen"); val s = segmenter(judge = judge::invoke)
        val hyp = words("dass wir um zehn anfangen.")
        val first = s.step(2.5, hyp, 0.0); val out = s.step(3.0, hyp, 0.5)
        assertTrue(first.isEmpty())
        assertEquals("judged", out.first().reason)
    }

    @Test fun judgeHoldsAClauseStillWaitingForItsVerb() = runBlocking {
        val judge = FakeJudge("anfangen"); val s = segmenter(judge = judge::invoke)
        val hyp = words("dass wir morgen nicht um neun.")
        s.step(2.5, hyp, 0.0)
        assertTrue(s.step(3.0, hyp, 0.5).isEmpty())
    }

    @Test fun judgeIsNotAskedAboutUnstableWordsOrTwiceAboutTheSame() = runBlocking {
        val judge = FakeJudge(); val s = segmenter(judge = judge::invoke)
        s.step(2.5, words("dass wir morgen"), 0.5)
        val notAsked = judge.asked.isEmpty()
        val hyp = words("dass wir morgen nicht")
        s.step(2.0, hyp, 0.5); s.step(2.0, hyp, 0.5); s.step(2.1, hyp, 0.6)
        assertTrue(notAsked)
        assertEquals(listOf("dass wir morgen nicht"), judge.asked)
    }

    @Test fun judgeVetoesACommaCutThatWouldStrandTheVerb() = runBlocking {
        val judge = FakeJudge("gemacht"); val s = segmenter(SegmenterConfig(softSegment = 4.0), judge::invoke)
        val hyp = words("weil wir das morgen um neun, und nicht später gemacht haben wollten und so")
        s.step(5.0, hyp, 0.0)
        assertTrue(s.step(5.5, hyp, 0.0).isEmpty())
    }

    @Test fun forcedCutPrefersThePointTheJudgeAccepts() = runBlocking {
        val judge = FakeJudge("gemacht"); val s = segmenter(SegmenterConfig(softSegment = 3.0, maxSegment = 4.0), judge::invoke)
        val hyp = words("wir haben das alles gestern gemacht") + words("weil es", start = 2.6) + words("nötig war und dann noch", start = 3.8)
        s.step(6.0, hyp, 0.0)
        val out = s.step(6.5, hyp, 0.0)
        assertEquals(listOf("wir haben das alles gestern gemacht"), out.texts())
        assertEquals("force", out.first().reason)
    }

    @Test fun forcedCutWaitsRatherThanCutWhereTheJudgeRefusesUpToTheHardLimit() = runBlocking {
        val judge = FakeJudge(); val s = segmenter(SegmenterConfig(softSegment = 3.0, maxSegment = 4.0, hardSegment = 6.0), judge::invoke)
        var hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so")
        s.step(6.0, hyp, 0.0)
        val waited = s.step(6.5, hyp, 0.0).isEmpty()
        hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so und weiter")
        s.step(7.0, hyp, 0.0)
        val out = s.step(7.5, hyp, 0.0)
        assertTrue(waited)
        assertEquals("force", out.first().reason)
    }

    @Test fun anEarlyFlickerDoesNotHoldBackALaterSentenceEnd() = runBlocking {
        val s = segmenter()
        s.step(3.0, words("Yeah yeah okay so we went home and slept. And then"), 0.0)
        val out = s.step(3.5, words("Yeah yeah yeah okay so we went home and slept. And then"), 0.0)
        assertEquals(listOf("Yeah yeah yeah okay so we went home and slept."), out.texts())
    }

    @Test fun aMostlyRewrittenWindowIsNotStable() = runBlocking {
        val s = segmenter()
        s.step(3.0, words("Ich habe gestern das Auto. Und dann"), 0.0)
        assertTrue(s.step(3.5, words("Mich hat gestern der Hund. Und dann"), 0.0).isEmpty())
    }

    @Test fun aLongGapAfterTheLastWordIsAPauseWhateverTheVadHears() = runBlocking {
        val s = segmenter(); val hyp = words("Nem tudom")
        s.step(1.0, hyp, 0.0)
        assertEquals("pause", s.step(2.5, hyp, 0.0).first().reason)
    }

    // clock times

    @Test fun clockTimes() {
        for ((source, expected) in listOf(
            "Wir fangen um halb elf an." to "Wir fangen um 10:30 an.",
            "erst um halb 11 anfangen" to "erst um 10:30 anfangen",
            "Es ist halb eins." to "Es ist 12:30.",
            "We beginnen om half negen." to "We beginnen om 8:30.",
            "Das Konzert ist um drei viertel zehn." to "Das Konzert ist um 9:45.",
            "um dreiviertel acht" to "um 7:45",
            "Wir treffen uns um Viertel vor sechs." to "Wir treffen uns um 5:45.",
            "Ik ben er om kwart voor twaalf." to "Ik ben er om 11:45.",
            "um 19 Uhr halb 8" to "um 19 Uhr 7:30",
        )) assertEquals(source, expected, Clock.normalise(source))
        for (text in listOf("Viertel nach vier", "kwart over twee", "Das ist nur halb so viel.", "Ich habe die Hälfte gegessen.", "halb voll")) {
            assertEquals(text, text, Clock.normalise(text))
        }
    }

    // echoes

    @Test fun garbledEnglishRepeatedIsAnEcho() {
        assertTrue(echoes("I put on the table go see the bag then.", "I put on the table go see the bag then."))
        assertTrue(echoes("She comes in hug me. Where is my cat?", "She comes in, hugs me. Where's my cat?"))
    }

    @Test fun aRealTranslationIsNotAnEcho() {
        assertTrue(!echoes("Nie, nie moja, twoja pewnie.", "No, it's not mine, probably yours."))
        assertTrue(!echoes("Dziękuję. Gdzie później się oddać?", "Thank you. Where to meet up later?"))
    }

    // language evidence

    @Test fun languageEvidence() {
        val here = listOf("en", "pl", "hu", "nl")
        for (text in listOf("A tudom, de a nyelvedől.", "Nem tudom, volám használt that volami.", "Chciałem poprosić o zapalniczkę.",
                            "Ale tego nie wiesz.", "Dat is gezellig, toch?")) assertEquals(text, true, Languages.evidence(text, here))
        for (text in listOf("Почему единицы на подниму?", "Não é nada pois.", "¿Dónde está el baño?")) assertEquals(text, false, Languages.evidence(text, here))
        assertNotEquals(false, Languages.evidence("Почему единицы на подниму?", listOf("en", "ru")))
        assertNull(Languages.evidence("Apoi zulas.", here))
        assertEquals("Polish, Hungarian and Dutch", Languages.list(listOf("pl", "hu", "nl")))
    }

    // catch-up

    @Test fun catchUp() {
        val backlog = Backlog()
        assertTrue(!backlog.brief(1.4) && backlog.brief(1.5) && backlog.pace(1.0) == 1.0 && abs(backlog.pace(2.0) - 1.1) < 1e-9 && backlog.pace(10.0) == 1.3)
    }

    // the commentary guard (the iPhone app's SpokenTests)

    @Test fun commentaryIsCaughtButTranslationsAreNot() {
        for (line in listOf("I'm sorry, but I can't translate that because it contains offensive language.",
                            "I cannot help with translating this content.", "This phrase contains profanity.",
                            "As an AI, I won't repeat that.", "Note: the original uses vulgar language.",
                            "I am not able to provide a translation of derogatory terms.")) {
            assertTrue(line, TranslationQuality.concern("Ty kurwo jebana, oddaj mi telefon.", line) != null)
        }
        for (line in listOf("I'm sorry, I didn't hear you.", "You fucking whore, give me back my phone.", "That's offensive, you know.",
                            "I can't help it, I'm tired.", "Get out of my room!", "Damn it, I've forgotten my keys again.")) {
            assertNull(line, TranslationQuality.concern("Kurwa.", line))
        }
    }
}
