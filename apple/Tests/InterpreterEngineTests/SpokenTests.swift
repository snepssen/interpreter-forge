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
}
