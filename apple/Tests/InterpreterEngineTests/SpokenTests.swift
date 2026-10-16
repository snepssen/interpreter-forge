import InterpreterCore
import XCTest
@testable import InterpreterEngine

/// What of a model's output is said aloud.
final class SpokenTests: XCTestCase {
    func testAnnouncementLineIsSkipped() {
        // TranslateGemma, into English, from snepssen's Polish "No więc, chcę tylko powiedzieć".
        XCTAssertEqual(Linguist.spoken("Okay, here's the English translation:\n\nSo, I just want to say"),
                       "So, I just want to say")
        XCTAssertEqual(Linguist.spoken("Note: this is fine"), "Note: this is fine")
    }

    /// Commentary is never spoken; translations of rude or apologetic speech are.
    func testCommentaryIsCaughtButTranslationsAreNot() {
        let commentary = [
            "I'm sorry, but I can't translate that because it contains offensive language.",
            "I cannot help with translating this content.",
            "This phrase contains profanity.",
            "As an AI, I won't repeat that.",
            "Note: the original uses vulgar language.",
            "I am not able to provide a translation of derogatory terms.",
        ]
        for line in commentary {
            XCTAssertNotNil(TranslationQuality.concern(source: "Ty kurwo jebana, oddaj mi telefon.", translation: line), line)
        }
        let translations = [
            "I'm sorry, I didn't hear you.",          // Przepraszam, nie słyszałem
            "You fucking whore, give me back my phone.",
            "That's offensive, you know.",
            "I can't help it, I'm tired.",            // the speaker can't help it, not the model
            "Get out of my room!",
            "Damn it, I've forgotten my keys again.",
        ]
        for line in translations {
            XCTAssertNil(TranslationQuality.concern(source: "Kurwa.", translation: line), line)
        }
    }

    func testFirstOfTwoGenderedFormsIsSaid() {
        XCTAssertEqual(Linguist.spoken("No, po prostu chciałem/chciałam powiedzieć."), "No, po prostu chciałem powiedzieć.")
        XCTAssertEqual(Linguist.spoken("Mam psa/kota."), "Mam psa/kota.")
    }

    /// TranslateGemma on a fragment of Italian it found ambiguous (2026-10-16).
    func testAlternativesAndClosingNotesAreNotSaid() {
        XCTAssertEqual(Linguist.spoken("He/She places the advertisement in the newspaper."),
                       "He places the advertisement in the newspaper.")
        XCTAssertEqual(Linguist.spoken("I’m asking you to judge how I look. / I’m asking you to tell me what you think"),
                       "I’m asking you to judge how I look.")
        XCTAssertEqual(Linguist.spoken("This is coming from the secretary and… (the sentence is incomplete in Italian)."),
                       "This is coming from the secretary and…")
        XCTAssertEqual(Linguist.spoken("Coffee and/or tea."), "Coffee and/or tea.")
        XCTAssertEqual(Linguist.spoken("Yes? Yes. But not *too* good, though."), "Yes? Yes. But not too good, though.")
        XCTAssertEqual(Linguist.spoken("It was **really** _that_ bad."), "It was really that bad.")
    }
}
