package com.snepssen.engine

import org.junit.Assert.assertEquals
import org.junit.Test

/** What of a model's output is said aloud: the iPhone app's SpokenTests. */
class SpokenTest {
    @Test fun announcementLineIsSkipped() {
        // TranslateGemma, into English, from snepssen's Polish "No więc, chcę tylko powiedzieć".
        assertEquals("So, I just want to say", Linguist.spoken("Okay, here's the English translation:\n\nSo, I just want to say"))
        assertEquals("Note: this is fine", Linguist.spoken("Note: this is fine"))
    }

    @Test fun firstOfTwoGenderedFormsIsSaid() {
        assertEquals("No, po prostu chciałem powiedzieć.", Linguist.spoken("No, po prostu chciałem/chciałam powiedzieć."))
        assertEquals("Mam psa/kota.", Linguist.spoken("Mam psa/kota."))
    }

    @Test fun closingNoteAndQuotesAreDropped() {
        assertEquals("It's raining cats and dogs.",
            Linguist.spoken("\"It's raining cats and dogs.\" (This is a somewhat unusual phrase in the original.)"))
        assertEquals("He said (twice) no.", Linguist.spoken("He said (twice) no."))
    }

    /** TranslateGemma on a fragment of Italian it found ambiguous (2026-10-16). */
    @Test fun alternativesAndClosingNotesAreNotSaid() {
        assertEquals("He places the advertisement in the newspaper.", Linguist.spoken("He/She places the advertisement in the newspaper."))
        assertEquals("I’m asking you to judge how I look.", Linguist.spoken("I’m asking you to judge how I look. / I’m asking you to tell me what you think"))
        assertEquals("This is coming from the secretary and…", Linguist.spoken("This is coming from the secretary and… (the sentence is incomplete in Italian)."))
        assertEquals("Coffee and/or tea.", Linguist.spoken("Coffee and/or tea."))
        assertEquals("Yes? Yes. But not too good, though.", Linguist.spoken("Yes? Yes. But not *too* good, though."))
        assertEquals("It was really that bad.", Linguist.spoken("It was **really** _that_ bad."))
    }
}
