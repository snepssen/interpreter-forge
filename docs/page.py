"""Interpreter's project page, as a catalogue.

Everything particular to this project lives here; `build.py` supplies the
chrome every page in the family shares. Adding a section is a dict in
`sections` — the jump navigation, which is derived from these, picks it up on
its own.

Prose is authored HTML. Every figure quoted here was measured: the run shown
is `tcrun samples/de_halting.wav` with TranslateGemma on an M1 Mac, the
conversation numbers are the README's, from a 70-minute recording, and the
round trip is `scripts/make-snepssen-samples.sh` through `tcrun --into`.
"""

FONTS = "fonts.css"

LIVE_SCREEN = """<div class="device-row">
  <figure class="phone" aria-label="The iPhone's live screen during the German sample">
    <div class="phone-top">
      <span class="phone-chip">◍ Any language → English</span>
      <span class="phone-icons" aria-hidden="true">☾ ⚙</span>
    </div>
    <div class="phone-feed">
      <div class="phone-line"><span class="lang">DE</span><span class="said">Also, I just wanted to say briefly…</span></div>
      <div class="phone-line"><span class="lang">DE</span><span class="said">that we won’t be meeting at nine o’clock.</span></div>
      <div class="phone-line latest"><span class="lang">DE</span><span class="said">but to start at 10:30.<span class="orig">sondern erst um halb elf anfangen.</span></span></div>
    </div>
    <div class="phone-hearing">◖ Hearing… <b>Der Grund ist, dass der Zug</b></div>
    <div class="phone-button" aria-hidden="true"><span></span></div>
    <div class="phone-status">Speaking · 4.2 s behind</div>
  </figure>
  <div class="device-notes">
    <img class="app-icon" src="icon.png" width="96" height="96" alt="Interpreter's icon: plain wavefronts arrive from the left, pass a glowing point, and leave on the right in cyan.">
    <p class="lede">The screen is mostly not looked at. The English is in your ear; the
    phone is in a pocket or face down on the table.</p>
    <p>So it answers three things at a glance. Whether it is on: one round button,
    with the microphone level as a ring around it. What it is doing: one line —
    listening, translating, or speaking and how far behind. What was just said:
    the newest translation large, with what was actually said under it, and a
    language chip when the language is certain.</p>
    <p class="caption">The live screen, rebuilt from the run in the next section
    rather than photographed from someone's real conversation.</p>
  </div>
</div>"""

GERMAN_RUN = (
    '<span class="muted">[ 0.00– 3.52] clause   │</span> Also, ich wollte eigentlich nur kurz sagen,\n'
    '  <span class="pass">#0</span>  lag 2.7 s → Also, I just wanted to say briefly…\n'
    '<span class="muted">[ 3.90– 6.70] clause   │</span> dass wir morgen nicht um neun,\n'
    '  <span class="pass">#1</span>  lag 4.6 s → that we won’t be meeting at nine o’clock.\n'
    '<span class="muted">[ 6.92– 9.80] sentence │</span> sondern erst um halb elf anfangen.\n'
    '  <span class="pass">#2</span>  lag 4.2 s → but to start at <b>10:30</b>.\n'
    '<span class="muted">[10.10–13.14] force    │</span> Der Grund ist, dass der Zug aus München\n'
    '<span class="muted">[13.52–15.92] pause    │</span> wegen Bauarbeiten ausfällt.\n'
    '  <span class="pass">#3</span>  lag 5.2 s → The reason is that the train from Munich…\n'
    '  <span class="pass">#4</span>  lag 5.0 s → …is cancelled due to construction work.\n'
    '<span class="muted">[17.98–21.74] clause   │</span> Wer kann, sollte vielleicht mit dem Auto kommen,\n'
    '  <span class="pass">#5</span>  lag 4.6 s → Those who can should perhaps come by car.\n'
    '\n'
    '<span class="muted">lag  median 5.0 s, max 6.6 s over 8 pieces</span>'
)

ITALIAN_RUN = (
    '<span class="muted">[ 2.30– 5.90] clause   │</span> No, scusate. Il treno parte alle 7 e un quarto,\n'
    '  <span class="pass">#1</span>  → No, sorry. The train leaves at 7:15.\n'
    '<span class="muted">[ 8.26–12.26] flush    │</span> Quindi ci vediamo in stazione verso le 7-5.\n'
    '  <span class="warn">#3</span>  unclear, not spoken\n'
    '      The clock time was unclear in speech recognition. Please repeat it.'
)

ROUND_TRIP = """  <table>
    <thead><tr><th>Snepssen speaks</th><th>Interpreted into</th><th>Words recognition heard right</th></tr></thead>
    <tbody>
      <tr><td>French</td><td>Italian</td><td>94%</td></tr>
      <tr><td>English</td><td>Polish</td><td>92%</td></tr>
      <tr><td>Dutch</td><td>Spanish</td><td>90%</td></tr>
      <tr><td>Spanish</td><td>Dutch</td><td>90%</td></tr>
      <tr><td>German</td><td>Hungarian</td><td>86%</td></tr>
      <tr><td>Italian</td><td>French</td><td>86%</td></tr>
      <tr><td>Hungarian</td><td>German</td><td>85%</td></tr>
      <tr><td>Polish</td><td>English</td><td>82%</td></tr>
    </tbody>
  </table>"""

MODELS = """  <table>
    <thead><tr><th>Translator</th><th>Meaning errors in 26 lines</th><th>Judges a complete thought</th><th>Memory</th></tr></thead>
    <tbody>
      <tr><td>TranslateGemma 4B <span class="tag published">recommended</span></td><td>0, the most natural English</td><td>no — cuts on pauses and punctuation</td><td>2.6 GB</td></tr>
      <tr><td>Qwen3 4B</td><td>3</td><td>17 of 17</td><td>2.8 GB</td></tr>
      <tr><td>Gemma 4 E4B</td><td>1</td><td>13 of 17</td><td>4.7 GB — a Mac, or a 12 GB iPhone</td></tr>
      <tr><td>Gemma 4 E2B</td><td>5</td><td>12 of 17</td><td>3.0 GB</td></tr>
    </tbody>
  </table>
  <table>
    <thead><tr><th>Recognition</th><th>Languages</th><th>Ten seconds of speech, M1 Mac</th></tr></thead>
    <tbody>
      <tr><td>Parakeet Ultra <span class="tag published">default</span></td><td>25 European</td><td>0.19 s, on the Neural Engine</td></tr>
      <tr><td>Whisper large-v3 Turbo</td><td>100, Norwegian among them</td><td>2.42 s</td></tr>
    </tbody>
  </table>"""

PAGE = {
    "meta": {
        "slug": "translate-core",
        "name": "Interpreter",
        "title": "Interpreter — live interpreting on your own device",
        "badge": "macOS · iPhone · on-device",
        "fonts": FONTS,
        "description": (
            "Live interpretation that waits for a complete thought, like a "
            "human interpreter, and speaks it in your language, entirely on "
            "a Mac or an iPhone."),
        "og_description": (
            "Any of 25 languages around you, in English, Polish, Hungarian, "
            "German, Dutch, French, Spanish or Italian in your ear a few "
            "seconds later. Nothing leaves the device."),
        "subhead": (
            "Sit at a table where everyone speaks something else, put your "
            "AirPods in, and hear it in your own language. It listens continuously, waits "
            "until a thought is complete the way an interpreter does, and "
            "speaks it in your ear while it keeps listening. Recognition, "
            "translation and the voice all run on the phone or Mac in front of "
            "you."),
        "stats": [
            "<b>25</b> languages heard, <b>8</b> spoken",
            "<b>~4–5 s</b> behind the speaker",
            "<b>0</b> bytes of speech leave the device",
        ],
    },

    "header_blocks": [
        {"kind": "raw", "html": LIVE_SCREEN},
    ],

    "sections": [
        {
            "id": "why",
            "jump": "Why",
            "eyebrow": "The problem",
            "heading": "Phrase by phrase is how a walkie-talkie works",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "Translation apps wait for you to stop talking, or translate "
                    "every half-sentence as it comes. The first is a "
                    "conversation in turns; the second is a stream of fragments "
                    "with the verb still to come, which in German or Hungarian "
                    "is often the part that mattered.",
                ]},
                {"kind": "prose", "text": [
                    "A human interpreter does neither. They let the speaker run "
                    "ahead, hold on until a thought is complete, then say it — "
                    "a few seconds behind, all the way through. That is the "
                    "behaviour this copies: listen without stopping, cut at the "
                    "end of a thought, translate it with what came before as "
                    "context, and speak it while the next one is already being "
                    "heard.",
                    "It is built for one table in particular: Polish, Hungarian "
                    "and Romanian around an English speaker, with Dutch words "
                    "dropped in. English is understood already, so it is shown, "
                    "kept as context and never spoken back.",
                ]},
            ],
        },
        {
            "id": "how",
            "jump": "How it cuts",
            "eyebrow": "How it works",
            "heading": "Deciding when a thought is complete",
            "blocks": [
                {"kind": "report", "text": (
                    'mic ─▶ voice activity ─▶ segmenter ─▶ translate ─▶ voice ─▶ headphones\n'
                    '                          ▲      │\n'
                    '                          └ ASR ◀┘  <span class="muted">re-reads what is not yet cut, every 0.5 s</span>'
                 ), "caption": (
                    "Recognition runs on the Neural Engine and translation on the "
                    "GPU, side by side, so hearing the next thought never waits "
                    "for the last one to be spoken.")},
                {"kind": "prose", "text": [
                    "Every half second the uncommitted tail of speech is "
                    "transcribed again, and words count as settled once two "
                    "passes agree on them. A piece is cut at the end of a "
                    "sentence that speech has carried on past, at a pause long "
                    "enough for this speaker, or at a comma once it has run four "
                    "seconds. At five it is cut wherever it can be, and at six "
                    "wherever it stands; the next piece picks up the sentence.",
                    "A general model such as Qwen is also asked, in a single "
                    "forward pass, whether the words so far can be translated "
                    "yet. That is why it speaks sooner in quick conversation: it "
                    "can cut at <em>“Nie wiem, czy zdążymy na pociąg.”</em> and "
                    "hold at <em>“Nie wiem, czy.”</em> TranslateGemma cannot be "
                    "asked, so it relies on the rules alone, and translates "
                    "better.",
                ]},
                {"kind": "heading", "text": "When it falls behind"},
                {"kind": "prose", "text": [
                    "Speech does not wait for the interpreter, and people speak "
                    "unevenly: they pause for effect, think aloud, build up "
                    "slowly. That is meant to queue, not be cut; the pauses are "
                    "context for the next piece. Pieces that pile up while it is "
                    "busy go out together as one translation, and once a second "
                    "of speech is queued the voice speeds up, to at most 1.3 "
                    "times. Everything is translated in full.",
                    "Some listeners would rather keep up than hear all of a long "
                    "story. <b>Summarise to keep up</b>, off unless chosen, says "
                    "only the gist once the interpreter is behind: "
                    "<em>“complaining about back pain and their boss.”</em> It "
                    "needs a translator that takes instructions, Qwen or Gemma 4.",
                ]},
            ],
        },
        {
            "id": "run",
            "jump": "A run",
            "eyebrow": "What it does",
            "heading": "A halting German announcement, as it is heard",
            "blocks": [
                {"kind": "report", "text": GERMAN_RUN, "caption": (
                    "The project's German sample through the native engine with "
                    "TranslateGemma, in real time on an M1 Mac. Lag is from the "
                    "end of what was said to the start of its English. "
                    "<span class=\"mono\">force</span> marks the five-second "
                    "ceiling: the sentence ran on, so it was cut and finished in "
                    "the next piece.")},
                {"kind": "prose", "text": [
                    "<b>“halb elf” is 10:30, not half past eleven.</b> A 4B "
                    "model reads European clock times the English way and got 3 "
                    "of 10 right, so German and Dutch half hours and quarters "
                    "are rewritten to digits before the model sees them. On "
                    "held-out times in seven languages: 14 of 14.",
                ]},
                {"kind": "report", "text": ITALIAN_RUN, "caption": (
                    "When recognition writes <span class=\"mono\">sette meno "
                    "cinque</span> as <span class=\"mono\">7-5</span>, there is "
                    "no telling whether that was 6:55 or something else. It is "
                    "shown with a request to repeat it, and not spoken.")},
            ],
        },
        {
            "id": "conversation",
            "jump": "Real talk",
            "eyebrow": "Real conversation",
            "heading": "Tuned on seventy minutes of a real kitchen table",
            "blocks": [
                {"kind": "prose", "text": [
                    "Samples read clearly are the easy case. The segmenter was "
                    "tuned on a 70-minute recording of English, Polish and "
                    "Hungarian, with Dutch words in it, from an iPhone's bottom "
                    "microphone. What that changed:",
                ]},
                {"kind": "raw", "html": """  <ul class="plain">
    <li>The median delay of spoken pieces went from 7.8 to 3.9 seconds, the worst from 24.9 to 12.8.</li>
    <li>Pieces cut by force fell from 75 to 11.</li>
    <li>916 of 1,022 pieces were English: shown, used as context, and left quiet.</li>
    <li>Accented English the recogniser mangles, which a model then “translates” into itself, is caught and not spoken: 40 of 101 would-be translations in the recording were that.</li>
    <li>A pause is measured from the last word heard, not only from the voice detector, which went on hearing “speech” in background noise for half a minute.</li>
  </ul>"""},
            ],
        },
        {
            "id": "voice",
            "jump": "The voice",
            "eyebrow": "The voice",
            "heading": "One voice, eight languages, 64 MB",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "The interpreter speaks with snepssen: one small Piper voice "
                    "that speaks English, Polish, Hungarian, German, Dutch, "
                    "French, Spanish and Italian as the same character, "
                    "whispery, tired and steady, rendering a sentence in "
                    "milliseconds on the device.",
                ]},
                {"kind": "prose", "text": [
                    "It began as an English voice. Its other languages were "
                    "taught from speech generated with the same vocal profile, "
                    "read from scripts written for each language's hard sounds, "
                    "cut, checked line by line and trained together. Sounds the "
                    "phonemizer gets wrong, Polish hard <em>dz</em>, Hungarian "
                    "silent <em>h</em>, or shares across languages that say them "
                    "differently, German, Dutch and Italian <em>r</em>, are "
                    "corrected before the voice sees them, by "
                    "<a href=\"https://github.com/snepssen/voice-polyglot\">voice-polyglot</a>'s "
                    "Polyphon; the apps carry a port of it held to the original "
                    "symbol for symbol. Each language plays at its own pace, "
                    "picked by ear, since the new languages were read faster "
                    "than the English.",
                    "<b>It is still training.</b> Native listeners understood its "
                    "Polish and Hungarian; German and Dutch sound native enough "
                    "to be rushed. A better-trained voice is a rebuild away.",
                ]},
                {"kind": "heading", "text": "Snepssen interpreting snepssen"},
                {"kind": "prose", "text": [
                    "The voice also makes the test speech. Each language is "
                    "spoken by snepssen, heard by the app's speech recognition "
                    "and interpreted into another, which tests the whole chain "
                    "and how legible the voice is at once:",
                ]},
                {"kind": "raw", "html": ROUND_TRIP},
                {"kind": "prose", "class": "caption", "text": [
                    "TranslateGemma, in real time on an M1 Mac, a halting "
                    "announcement or a fluent one per language. The misses that "
                    "mattered were clock times: <em>fél tizenegykor</em> heard "
                    "wrong became the wrong time in German. That is the next "
                    "thing to make safe.",
                ]},
            ],
        },
        {
            "id": "models",
            "jump": "Models",
            "eyebrow": "Models",
            "heading": "Choose the translator; it downloads once",
            "blocks": [
                {"kind": "prose", "text": [
                    "Models are picked in the app on first launch, and can be "
                    "added, switched or deleted in Settings. One translator is "
                    "in memory at a time; on an 8 GB iPhone 17 a 4B model fits "
                    "beside recognition with the increased-memory entitlement. "
                    "Measured on the same 26 lines in ten languages and a "
                    "17-case test of complete thoughts:",
                ]},
                {"kind": "raw", "html": MODELS},
                {"kind": "prose", "class": "caption", "text": [
                    "Into English, TranslateGemma's is the most natural; into "
                    "Polish and Hungarian the comparison is still to be made.",
                ]},
            ],
        },
        {
            "id": "apps",
            "jump": "The apps",
            "eyebrow": "On the iPhone and the Mac",
            "heading": "One engine, two apps",
            "blocks": [
                {"kind": "cards", "cards": [
                    {"title": "Headphone microphone", "formats": "iPhone · iOS 26+",
                     "note": "AirPods sit closer to the people talking than a "
                             "phone in a pocket. Recorded in full quality where "
                             "they support it, and asked to hear the whole room "
                             "rather than mainly you."},
                    {"title": "Captions only", "formats": "iPhone · Mac",
                     "note": "For a phone on the table when nobody has "
                             "headphones: translations on screen, nothing "
                             "spoken over the room."},
                    {"title": "A dark screen", "formats": "iPhone",
                     "note": "Interpreting is foreground-only, so the screen "
                             "stays awake while live. The moon turns it black "
                             "but for the last line and a Stop button."},
                    {"title": "Any language, or only these", "formats": "iPhone · Mac",
                     "note": "Everything that isn't your language is translated. "
                             "Naming the languages at the table instead makes "
                             "a misheard Russian for a Polish speaker stay "
                             "quiet."},
                    {"title": "Into your language", "formats": "iPhone · Mac",
                     "note": "Pick the language you hear: any of the voice's "
                             "eight. What is already in it is shown and kept "
                             "as context, not spoken. Untrained languages, "
                             "with an accent, are behind a setting."},
                ]},
            ],
        },
        {
            "id": "get",
            "jump": "Get it",
            "eyebrow": "Getting it",
            "heading": "Built from source, for now",
            "blocks": [
                {"kind": "prose", "text": [
                    "There is no App Store build. The apps need an Apple silicon "
                    "Mac with macOS 14, or an iPhone with 8 GB of memory, and "
                    "Xcode to build them. espeak-ng's data comes from "
                    "<a href=\"https://github.com/snepssen/voice-forge\">voice-forge</a>, "
                    "cloned beside this repository, and the voice from "
                    "<a href=\"https://github.com/snepssen/voice-polyglot\">voice-polyglot</a>. "
                    "Everything to build them is here: the app's source and "
                    "build scripts, and in voice-polyglot the whole pipeline "
                    "the voice was made with, from the scripts it read to "
                    "training and export. The voice itself is fetched by the "
                    "build from voice-polyglot's "
                    "<a href=\"https://github.com/snepssen/voice-polyglot/releases\">releases</a>, "
                    "the newest one each time: <b>still in training</b>, marked "
                    "with an asterisk and the epoch it was exported at.",
                ]},
                {"kind": "raw", "html": """  <pre class="code"><span class="c"># beside each other</span>
git clone https://github.com/snepssen/voice-forge
git clone https://github.com/snepssen/translate-core
cd translate-core

apple/build.sh             <span class="c"># the Mac app: apple/Interpreter.app</span>
apple/iOS/build-ios.sh     <span class="c"># the iPhone app, onto a connected iPhone</span>
uv run translate-core live <span class="c"># the Python rig the apps were measured against</span></pre>"""},
                {"kind": "prose", "text": [
                    "The iPhone build signs with your own development team, set "
                    "in <span class=\"mono\">apple/iOS/project.yml</span>. The "
                    "first launch downloads speech recognition and the "
                    "translator you choose — about 3 GB, best on Wi-Fi.",
                ]},
            ],
        },
        {
            "id": "roadmap",
            "jump": "Roadmap",
            "eyebrow": "Where it is going",
            "heading": "Roadmap",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "The goal does not change: be included in a conversation "
                    "you would otherwise sit out, in your own language, with "
                    "nothing leaving your device.",
                ]},
                {"kind": "cards", "cards": [
                    {"title": "Finish training the voice", "formats": "now",
                     "note": "Three to four days of training, a check-in every "
                             "25 epochs, until the voice is indistinguishable "
                             "by ear; the apps pick up each better export."},
                    {"title": "Safe numbers", "formats": "next",
                     "note": "A clock time or number recognition was unsure of "
                             "is asked about, not spoken: the wrong time said "
                             "with confidence is the worst mistake it makes."},
                    {"title": "Real rooms", "formats": "next",
                     "note": "Many voices, crosstalk, a noisy kitchen: the "
                             "70-minute recording rerun after every large "
                             "change, and new ones in other languages."},
                    {"title": "A translator per language", "formats": "next",
                     "note": "TranslateGemma, Qwen and Gemma 4 compared into "
                             "Polish and Hungarian, not only English, and the "
                             "best chosen for each."},
                    {"title": "Timing word by word", "formats": "later",
                     "note": "Voice Forge's per-word duration control in the "
                             "polyglot voice, for the odd phrase that still "
                             "rushes inside a sentence."},
                    {"title": "One engine, shared", "formats": "later",
                     "note": "Voice Forge, voice-polyglot and this app each "
                             "fetching the latest of the others, instead of "
                             "keeping copies."},
                    {"title": "Android", "formats": "later",
                     "note": "The voice and phonemizer already run there; "
                             "recognition and translation have Android "
                             "runtimes. As phones gain memory, the room for a "
                             "better translator grows with them."},
                    {"title": "The App Store", "formats": "when permitted",
                     "note": "Publishing depends on the permission of everyone "
                             "whose work is inside: espeak-ng and Piper are "
                             "GPL, and the voice was trained on speech "
                             "generated with Suno. This app is the working "
                             "demonstration that request will rest on. Until "
                             "then it is what it is today: open source, built "
                             "from source."},
                ]},
            ],
        },
        {
            "id": "limits",
            "jump": "Limits",
            "eyebrow": "Honesty",
            "heading": "What it is not",
            "blocks": [
                {"kind": "prose", "text": [
                    "<b>It is not a certified interpreter</b>, and should not be "
                    "relied on where a mistranslation costs more than a repeated "
                    "question: a doctor, a contract, a police station. A 4B "
                    "model gets most things right and some things confidently "
                    "wrong, and short or garbled phrases are where it goes wrong "
                    "most.",
                    "Recognition can invent words from faint speech or noise, "
                    "and it covers 25 European languages; Norwegian and the "
                    "rest need Whisper, which is about ten times slower. It "
                    "speaks eight languages well; others only through a "
                    "setting, with an accent. Into languages other than English "
                    "the translators are less tested, and Qwen's Polish is "
                    "rough. On the iPhone it works only while the app is open.",
                    "It is still being tested in the field. The numbers above "
                    "are from recordings and one kitchen table, not from many "
                    "people in many rooms.",
                ]},
            ],
        },
    ],

    "contact_note": (
        "There is no analytics here and no crash reporter. If it mistranslated "
        "something in a way that mattered, the source sentence and what it said "
        "are the most useful thing you can send."),

    "footer": [
        '<a href="https://github.com/snepssen/translate-core">github.com/snepssen/translate-core</a> '
        '· part of the <a href="https://snepssen.github.io/tools-core/">snepssen workshop</a>',
    ],
}
