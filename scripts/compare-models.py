"""Candidate translation models, side by side on the same lines.

    uv run python scripts/compare-models.py models/qwen3-4b-instruct-2507-4bit models/translategemma-4b-it-4bit ...

For each model: every line translated (told the source language, as the app
can from Apple's language detector, and with the clock-time rewrite applied
first, as the app does), the complete-thought judge on its test set, the mean
time per line, and the peak memory. The judgement of the translations is left
to a reader: the reference meaning is printed beside each one.
"""

import gc
import re
import sys
from pathlib import Path
from time import perf_counter

import mlx.core as mx
from mlx_lm import generate, load

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from translate_core.clock import normalise  # noqa: E402
from translate_core.judge import COMPLETE  # noqa: E402
from translate_core.languages import LANGUAGES  # noqa: E402
from translate_core.translate import SYSTEM  # noqa: E402

LINES = [  # (source language, text, reference meaning)
    ("pl", "Pierku A, myślałem, że idziesz, wychodzisz. Chciałem poprosić o zapalniczkę.", "I thought you were leaving. I wanted to ask for a lighter."),
    ("pl", "Masz papierosy?", "Do you have cigarettes?"),
    ("pl", "Nie, nie moja, twoja pewnie.", "No, not mine, probably yours."),
    ("pl", "A też przerwę opowiadałeś mu o tym jak tego kota znalazłeś?", "And did you tell him about how you found that cat?"),
    ("pl", "Moja babcia zawsze robiła kapustę w beczce w piwnicy.", "My grandmother always made cabbage in a barrel in the basement."),
    ("pl", "Spotkajmy się o wpół do ósmej przed dworcem.", "Let's meet at 7:30 in front of the station."),
    ("pl", "Nie ma sprawy, zaraz ci to przyniosę.", "No problem, I'll bring it to you right away."),
    ("pl", "Dziękuję bardzo.", "Thank you very much."),
    ("pl", "Nie mój cyrk, nie moje małpy.", "Not my circus, not my monkeys."),
    ("hu", "Miért nem megy románul?", "Why doesn't it work in Romanian?"),
    ("hu", "Oké, most próbáljuk meg magyarul meg mindenféle nyelven.", "OK, now let's try it in Hungarian and all sorts of languages."),
    ("hu", "Nem tudom, mikor jön a busz, de szerintem késik.", "I don't know when the bus is coming, but I think it's late."),
    ("hu", "Nincs összetörve, csak egy kicsit karcos.", "It isn't broken, just a little scratched."),
    ("hu", "Holnap reggel megyünk a piacra, jössz velünk?", "We're going to the market tomorrow morning, are you coming with us?"),
    ("hu", "Ez nem az én asztalom.", "That's not my business (lit. not my table)."),
    ("nl", "Praten jullie Nederlands?", "Do you (all) speak Dutch?"),
    ("nl", "Het is echt gezellig hier, maar het bier is te warm.", "It's really cosy here, but the beer is too warm."),
    ("nl", "We beginnen om half negen.", "We start at 8:30."),
    ("ro", "Da, asta zic, merge.", "Yes, that's what I'm saying, it works."),
    ("ro", "Nu înțeleg de ce nu merge în română.", "I don't understand why it doesn't work in Romanian."),
    ("no", "Snakker du norsk?", "Do you speak Norwegian?"),
    ("sv", "Kan du hjälpa mig med väskan?", "Can you help me with the bag?"),
    ("de", "Also, ich wollte eigentlich nur kurz sagen, dass wir morgen nicht um 9, sondern erst um halb elf anfangen.", "...we start tomorrow at 10:30, not at 9."),
    ("it", "Il treno parte alle sette e un quarto, non alle sette.", "The train leaves at 7:15, not at 7."),
    ("fr", "Je pense que le projet avance bien, mais il faudrait vérifier les chiffres.", "I think the project is going well, but the figures should be checked."),
    ("es", "Si tenéis preguntas, podéis escribirme por correo.", "If you have questions, you can email me."),
]

NAMES = {"no": "Norwegian"}  # outside Parakeet's 25, so not in LANGUAGES

JUDGE = [  # (start of an utterance, can it be translated yet?)
    ("Also, ich wollte eigentlich nur kurz sagen", True), ("dass wir morgen nicht um 9", False),
    ("dass wir morgen nicht um 9, sondern erst um halb elf anfangen.", True), ("Der Grund ist, dass der Zug aus München", False),
    ("à ce que nous avions prévu au départ", True), ("Il treno parte alle 7 e un quarto.", True),
    ("Quindi ci vediamo in stazione verso le.", False), ("Hoy vamos a hablar del nuevo horario de la.", False),
    ("Hoy vamos a hablar del nuevo horario de la biblioteca.", True), ("Ik heb gisteren met mijn broer.", False),
    ("Ik heb gisteren met mijn broer gebeld.", True), ("Wer kann, sollte vielleicht mit dem Auto kommen, und wer kein Auto hat,", False),
    ("Danke.", True), ("Nie wiem, czy.", False), ("Nie wiem, czy zdążymy na pociąg.", True),
    ("Wir müssen das bis Freitag.", False), ("Wir müssen das bis Freitag erledigen.", True),
]


def prompt_for(path: Path, tokenizer, system: str, user: str, source: str | None = None, translate: bool = True):
    """The model's own way of being asked: TranslateGemma's template takes the
    source language and no instructions; general models take ours."""
    if "translategemma" in path.name:
        if translate:
            content = [{"type": "text", "source_lang_code": source, "target_lang_code": "en", "text": user}]
            return tokenizer.apply_chat_template([{"role": "user", "content": content}], add_generation_prompt=True)
        text = f"<bos><start_of_turn>user\n{system}\n\n{user}<end_of_turn>\n<start_of_turn>model\n"
        return tokenizer.encode(text, add_special_tokens=False)
    if translate and source:
        user = f"Translate from {NAMES.get(source) or LANGUAGES[source]}: {user}"
    messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    # Gemma 4 thinks out loud unless told not to: seconds of reasoning per line.
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True, enable_thinking=False)


def run(path: Path) -> None:
    mx.reset_peak_memory()
    model, tokenizer = load(str(path))
    for stop in ("<end_of_turn>", "<turn|>", "<|im_end|>"):
        if stop in tokenizer.get_vocab():
            tokenizer.add_eos_token(stop)
    loaded = mx.get_peak_memory() / 1e9

    def translate(text, source):
        p = prompt_for(path, tokenizer, SYSTEM, normalise(text), source)
        return generate(model, tokenizer, prompt=p, max_tokens=160, verbose=False).strip()

    yes = mx.array(sorted({tokenizer.encode(w, add_special_tokens=False)[0] for w in ("yes", "Yes", " yes", " Yes")}))
    no = mx.array(sorted({tokenizer.encode(w, add_special_tokens=False)[0] for w in ("no", "No", " no", " No")}))

    def complete(text):
        text = re.sub(r"[.?!…]+$", "", text.strip())
        p = prompt_for(path, tokenizer, COMPLETE, f'"{text}"', translate=False)
        logits = model(mx.array([p]))[0, -1]
        return bool((logits[yes].max() > logits[no].max()).item())

    translate("Hallo.", "de")
    print(f"\n===== {path.name}  (weights in memory {loaded:.2f} GB)")
    times = []
    for source, text, want in LINES:
        t0 = perf_counter()
        out = translate(text, source)
        times.append(perf_counter() - t0)
        print(f"[{source}] {text}\n     want {want}\n     got  {out}")
    judged = sum(complete(text) == want for text, want in JUDGE)
    print(f"--- {path.name}: {sum(times) / len(times) * 1000:.0f} ms a line, judge {judged}/{len(JUDGE)}, "
          f"peak memory {mx.get_peak_memory() / 1e9:.2f} GB")
    del model, tokenizer
    gc.collect()
    mx.clear_cache()


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        run(Path(arg))
