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
}
