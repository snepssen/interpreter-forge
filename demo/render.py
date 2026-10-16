"""Turn a tcrun run into a demo video: the original picture and sound (the
sound turned down), the interpreter's voice where it played, and captions for
both: what is being heard, and what the interpreter is saying.

    python3 demo/render.py <clip.mp4> <run dir> <out.mp4> --from pl [--turns table-talk-turns.json]

The run dir is tcrun's --out: pieces.json gives every heard piece and every
translation with when it played and for how long; listen.wav's right channel
is the interpreter. The clip's language labels the captions; for a montage of
turns, --turns gives each turn's clip, so each piece is labelled by the turn
it falls in.
"""
import argparse, json, os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
LATO = os.path.expanduser("~/Library/Fonts/Lato-{}.ttf")
NAMES = {"pl": "Polish", "hu": "Hungarian", "it": "Italian", "fr": "French", "de": "German", "nl": "Dutch",
         "en": "English", "es": "Spanish"}
INK, PAPER, AMBER, MIST = (18, 22, 31), (244, 241, 234), (232, 162, 58), (190, 196, 206)


def font(style, size):
    return ImageFont.truetype(LATO.format(style), size)


def wrap(draw, text, face, width, lines):
    words, out, line = text.split(), [], ""
    for word in words:
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=face) <= width or not line:
            line = trial
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    if len(out) > lines:  # keep the end: it is what is being said now
        out = out[-lines:]
        out[0] = "…" + out[0]
    return out


def pill(draw, x, y, text, face, fill, ink):
    w = draw.textlength(text, font=face)
    draw.rounded_rectangle((x, y, x + w + 28, y + face.size + 16), radius=(face.size + 16) // 2, fill=fill)
    draw.text((x + 14, y + 6), text, font=face, fill=ink)
    return x + w + 28


def frame(heard, heard_lang, said, lag, into):
    """One caption state: the band over the bottom of the picture, transparent elsewhere."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    band, fade = 252, 36  # a near-opaque band, whatever the picture behind it, with a short fade above
    for i in range(fade):
        d.line([(0, H - band - fade + i), (W, H - band - fade + i)], fill=(*INK, int(224 * i / fade)))
    d.rectangle((0, H - band, W, H), fill=(*INK, 224))
    small, label, big = font("Italic", 26), font("Bold", 20), font("Bold", 38)
    if heard:
        pill(d, 56, H - 236, f"HEARD · {NAMES.get(heard_lang, heard_lang).upper()}", label, (70, 78, 94, 255), (*PAPER, 255))
        for n, line in enumerate(wrap(d, heard, small, W - 112, 1)):
            d.text((56, H - 198 + n * 32), line, font=small, fill=(*MIST, 255))
    if said:
        x = pill(d, 56, H - 152, f"INTERPRETER · {NAMES.get(into, into).upper()}", label, (*AMBER, 255), (*INK, 255))
        if lag is not None:
            d.text((x + 14, H - 146), f"{lag:.1f} s behind the speaker", font=font("Regular", 20), fill=(*MIST, 255))
        for n, line in enumerate(wrap(d, said, big, W - 112, 2)):
            d.text((56, H - 112 + n * 46), line, font=big, fill=(*PAPER, 255))
    return img


def main():
    p = argparse.ArgumentParser()
    p.add_argument("clip"); p.add_argument("run"); p.add_argument("out")
    p.add_argument("--from", dest="lang", required=True)
    p.add_argument("--turns")
    a = p.parse_args()
    run = json.load(open(os.path.join(a.run, "pieces.json")))
    into = run["into"]

    # The language heard at time t: the clip's, or the turn's in a montage.
    spans = []
    if a.turns:
        t = 0.0
        for turn in json.load(open(a.turns)):
            length = turn["to"] - turn["from"] + 0.8
            spans.append((t, t + length, turn["clip"].split("-")[0]))
            t += length
    def lang_at(t):
        return next((l for s, e, l in spans if s <= t < e), a.lang)

    heard = sorted(run["heard"], key=lambda h: h["start"])
    said = sorted(run["said"], key=lambda s: s["start"])
    unsaid = {u["index"]: u["why"] for u in run["unsaid"]}
    listen = os.path.join(a.run, "listen.wav")
    total = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                           "-of", "csv=p=0", listen]).decode()) + 1.0

    # Every moment the captions change, and what they show in between.
    marks = {0.0, total}
    for h in heard:
        marks |= {h["start"], h["end"] + 0.6}
    for s in said:
        marks |= {s["start"], s["start"] + s["seconds"]}
    marks = sorted(m for m in marks if 0 <= m <= total)

    def state(t):
        h = next((h for h in reversed(heard) if h["start"] <= t < h["end"] + 0.6), None)
        s = next((s for s in reversed(said) if s["start"] <= t < s["start"] + s["seconds"]), None)
        heard_text = h["text"] if h else ""
        if h and unsaid.get(h["index"]) == "understood":
            heard_text += "   (already " + NAMES.get(into, into) + ": not interpreted)"
        return (heard_text, lang_at(h["start"]) if h else a.lang,
                s["translation"] if s else "", round(s["lag"], 1) if s else None)

    work = tempfile.mkdtemp(prefix="render-")
    entries, last, n = [], None, 0
    for t0, t1 in zip(marks, marks[1:]):
        st = state((t0 + t1) / 2)
        if st != last:
            path = os.path.join(work, f"c{n:04d}.png"); n += 1
            frame(*st, into).save(path)
            entries.append([path, t1 - t0]); last = st
        else:
            entries[-1][1] += t1 - t0
    with open(os.path.join(work, "captions.txt"), "w") as f:
        for path, dur in entries:
            f.write(f"file '{path}'\nduration {dur:.3f}\n")
        f.write(f"file '{entries[-1][0]}'\n")

    # Picture held on its last frame until the interpreter has finished; the
    # speaker at a third of their level, the interpreter over them.
    clip_len = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                              "-of", "csv=p=0", a.clip]).decode())
    hold = max(0.0, total - clip_len)
    graph = (f"[0:v]scale={W}:{H}:force_original_aspect_ratio=decrease,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=0x12161f,"
             f"fps=30,tpad=stop_mode=clone:stop_duration={hold:.2f}[v];"
             f"[2:v]format=rgba[c];[v][c]overlay=0:0:shortest=0,format=yuv420p[vout];"
             f"[0:a]aresample=48000,aformat=channel_layouts=stereo,volume=0.32,apad[a0];"
             f"[1:a]pan=mono|c0=c1,aresample=48000,aformat=channel_layouts=stereo,volume=1.15[a1];"
             f"[a0][a1]amix=inputs=2:normalize=0:duration=longest[aout]")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a.clip, "-i", listen,
                    "-f", "concat", "-safe", "0", "-i", os.path.join(work, "captions.txt"),
                    "-filter_complex", graph, "-map", "[vout]", "-map", "[aout]", "-t", f"{total:.2f}",
                    "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-b:v", "1100k", "-maxrate", "1400k",
                    "-bufsize", "2800k", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
                    "-movflags", "+faststart", a.out], check=True)
    print(f"{a.out}: {total:.1f} s, {os.path.getsize(a.out) / 1e6:.1f} MB, {len(entries)} caption states")


if __name__ == "__main__":
    main()
