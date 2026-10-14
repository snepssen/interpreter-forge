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

    func testFirstOfTwoGenderedFormsIsSaid() {
        XCTAssertEqual(Linguist.spoken("No, po prostu chciałem/chciałam powiedzieć."), "No, po prostu chciałem powiedzieć.")
        XCTAssertEqual(Linguist.spoken("Mam psa/kota."), "Mam psa/kota.")
    }
}
