#!/usr/bin/env python3
"""Generates the game's art and sound assets (stdlib only, no downloads):

  assets/pieces/{w,b}{K,Q,R,B,N,P}.svg   flat, outlined chess pieces
  assets/sfx/{move,capture,check,game_end}.wav   short procedural sounds
  icon.svg                                 project icon (knight on a board square)

Run from the project root:  python3 tools/gen_assets.py
Swap in any other piece set by replacing the 12 SVGs; nothing else references the art style.
"""
import math
import os
import random
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------- pieces

COLORS = {
    "w": {"fill": "#F4ECDC", "stroke": "#35291F"},
    "b": {"fill": "#2B2624", "stroke": "#B8A78D"},
}
BASE = '<rect x="24" y="82" width="52" height="10" rx="3"/>'

# Shapes live in a 100x100 box; {stroke} lets details use the outline colour.
SHAPES = {
    "P": """
  <circle cx="50" cy="30" r="11"/>
  <path d="M38 50 C38 44 43 41 50 41 C57 41 62 44 62 50 Z"/>
  <path d="M40 50 C39 62 35 72 30 82 H70 C65 72 61 62 60 50 Z"/>""",
    "R": """
  <path d="M28 18 H38 V26 H45 V18 H55 V26 H62 V18 H72 V34 H28 Z"/>
  <path d="M33 34 H67 L65 74 H35 Z"/>
  <path d="M30 74 H70 V82 H30 Z"/>""",
    "N": """
  <path d="M32 82 C33 66 38 60 43 56 L37 53 C29 51 22 46 22 40 C22 36 26 33 30 31 L39 24 L44 12 L50 20 C60 20 68 26 73 36 C78 48 76 66 74 82 Z"/>
  <circle cx="42" cy="30" r="2.5" fill="{stroke}" stroke="none"/>
  <circle cx="27" cy="41" r="1.6" fill="{stroke}" stroke="none"/>""",
    "B": """
  <circle cx="50" cy="15" r="4.5"/>
  <path d="M50 20 C38 28 32 42 34 58 H66 C68 42 62 28 50 20 Z"/>
  <path d="M48 30 L59 45" fill="none"/>
  <path d="M31 58 H69 L71 66 H29 Z"/>
  <path d="M33 66 L31 82 H69 L67 66 Z"/>""",
    "Q": """
  <path d="M26 34 L34 68 H66 L74 34 L66 54 L62 26 L56 54 L50 22 L44 54 L38 26 L34 54 Z"/>
  <circle cx="25" cy="29" r="3.5"/>
  <circle cx="37.5" cy="21" r="3.5"/>
  <circle cx="50" cy="17" r="3.5"/>
  <circle cx="62.5" cy="21" r="3.5"/>
  <circle cx="75" cy="29" r="3.5"/>
  <path d="M32 68 H68 L70 76 H30 Z"/>
  <path d="M29 76 H71 V82 H29 Z"/>""",
    "K": """
  <path d="M50 6 V22 M43 13 H57" fill="none" stroke-width="4"/>
  <path d="M40 26 C40 22 60 22 60 26 L68 68 H32 Z"/>
  <path d="M35 46 H65" fill="none"/>
  <path d="M30 68 H70 L72 76 H28 Z"/>
  <path d="M29 76 H71 V82 H29 Z"/>""",
}

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 100 100">
<g fill="{fill}" stroke="{stroke}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round">{body}
  {base}
</g>
</svg>
"""


def write_pieces():
    out = os.path.join(ROOT, "assets", "pieces")
    os.makedirs(out, exist_ok=True)
    for color, palette in COLORS.items():
        for letter, body in SHAPES.items():
            svg = SVG.format(body=body.format(**palette), base=BASE, **palette)
            with open(os.path.join(out, f"{color}{letter}.svg"), "w") as f:
                f.write(svg)
    # Project icon: black knight on a light board square.
    icon = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 100 100">\n'
        '<rect width="100" height="100" rx="14" fill="#D9C7A7"/>\n'
        '<rect x="50" width="50" height="50" fill="#7A5C44"/><rect y="50" width="50" height="50" fill="#7A5C44"/>\n'
        '<g fill="{fill}" stroke="{stroke}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round">'
        f"{SHAPES['N'].format(**COLORS['b'])}\n  {BASE}\n</g>\n</svg>\n"
    ).format(**COLORS["b"])
    with open(os.path.join(ROOT, "icon.svg"), "w") as f:
        f.write(icon)


# --------------------------------------------------------------------------- sounds

SAMPLE_RATE = 44100


def tone(freq, duration, decay=30.0, volume=0.5, harmonics=(1.0,)):
    n = int(duration * SAMPLE_RATE)
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        s = sum(a * math.sin(2 * math.pi * freq * (k + 1) * t) for k, a in enumerate(harmonics))
        out.append(s * math.exp(-decay * t) * volume)
    return out


def noise(duration, decay=50.0, volume=0.5, smooth=6):
    rng = random.Random(7)
    n = int(duration * SAMPLE_RATE)
    raw = [rng.uniform(-1, 1) for _ in range(n)]
    out = []
    acc = 0.0
    for i in range(n):  # crude low-pass for a woody, not hissy, click
        acc += (raw[i] - acc) / smooth
        out.append(acc * math.exp(-decay * i / SAMPLE_RATE) * volume)
    return out


def mix(*layers):
    n = max(len(l) for l in layers)
    return [sum(l[i] if i < len(l) else 0.0 for l in layers) for i in range(n)]


def concat(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def silence(duration):
    return [0.0] * int(duration * SAMPLE_RATE)


def write_wav(name, samples):
    out = os.path.join(ROOT, "assets", "sfx")
    os.makedirs(out, exist_ok=True)
    fade = min(400, len(samples))
    for i in range(fade):  # avoid clicks at the end
        samples[-1 - i] *= i / fade
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples)
    with wave.open(os.path.join(out, name + ".wav"), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(data)


def write_sounds():
    write_wav("move", mix(noise(0.09, decay=70, volume=0.7), tone(230, 0.09, decay=45, volume=0.35, harmonics=(1, 0.3))))
    write_wav("capture", mix(noise(0.16, decay=35, volume=0.9, smooth=10), tone(120, 0.16, decay=22, volume=0.5, harmonics=(1, 0.5, 0.2))))
    write_wav("check", concat(tone(880, 0.08, decay=25, volume=0.4), silence(0.03), tone(1175, 0.12, decay=18, volume=0.4)))
    write_wav("game_end", concat(
        tone(523.25, 0.14, decay=12, volume=0.35, harmonics=(1, 0.4)),
        tone(659.25, 0.14, decay=12, volume=0.35, harmonics=(1, 0.4)),
        tone(783.99, 0.14, decay=12, volume=0.35, harmonics=(1, 0.4)),
        mix(tone(1046.5, 0.7, decay=5, volume=0.3, harmonics=(1, 0.4)), tone(523.25, 0.7, decay=5, volume=0.2)),
    ))


if __name__ == "__main__":
    write_pieces()
    write_sounds()
    print("assets written")
