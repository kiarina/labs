"""Synthesize the lab's sound effects and background music (WAV, 44.1 kHz,
16-bit mono) with the standard library only, so nothing with a license is
needed and nothing binary goes into Git.

python3 make_sounds.py <out dir>   -> <out>/sounds/sfx/*.wav, <out>/sounds/bgm/*.wav
"""

import math
import os
import random
import struct
import sys
import wave

RATE = 44100
random.seed(7)


def note(name):
    """'A4' -> Hz."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    n = names[name[0]]
    rest = name[1:]
    if rest.startswith("#"):
        n += 1
        rest = rest[1:]
    elif rest.startswith("b"):
        n -= 1
        rest = rest[1:]
    return 440.0 * 2 ** ((n + (int(rest) - 4) * 12) / 12)


def tone(freq, dur, vol=0.5, shape="sine", attack=0.005, release=0.08):
    out = []
    n = int(dur * RATE)
    for i in range(n):
        t = i / RATE
        if shape == "sine":
            v = math.sin(2 * math.pi * freq * t)
        elif shape == "tri":
            v = 2 / math.pi * math.asin(math.sin(2 * math.pi * freq * t))
        elif shape == "square":
            v = 0.6 if math.sin(2 * math.pi * freq * t) >= 0 else -0.6
        elif shape == "bell":
            v = (math.sin(2 * math.pi * freq * t) + 0.4 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-t * 6))
        else:
            v = random.uniform(-1, 1)
        env = min(1.0, t / attack) if attack > 0 else 1.0
        env *= min(1.0, (dur - t) / release) if release > 0 else 1.0
        out.append(v * vol * max(0.0, env))
    return out


def silence(dur):
    return [0.0] * int(dur * RATE)


def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] for t in tracks if i < len(t)) for i in range(n)]


def place(track, at, length):
    out = [0.0] * length
    start = int(at * RATE)
    for i, v in enumerate(track):
        if start + i < length:
            out[start + i] += v
    return out


def write(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = min(1.0, 0.9 / peak)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s * scale * 32767)) for s in samples))


def seq(notes, beat, shape, vol, length=None):
    """notes: [(name or None, beats)]."""
    total = sum(b for _, b in notes) * beat
    length = length or int(total * RATE)
    out = [0.0] * length
    at = 0.0
    for name, beats in notes:
        if name:
            out = mix(out, place(tone(note(name), beats * beat * 0.95, vol, shape, release=0.05), at, length))
        at += beats * beat
    return out


def loop_bgm(chords, melody, beat, bass_shape, lead_shape, pad_vol, lead_vol, bars):
    length = int(bars * 4 * beat * RATE)
    out = [0.0] * length
    for bar in range(bars):
        chord = chords[bar % len(chords)]
        at = bar * 4 * beat
        # Arpeggiated pad, eighth notes.
        for k in range(8):
            out = mix(out, place(tone(note(chord[k % len(chord)]), beat * 0.48, pad_vol, "tri", release=0.04), at + k * beat / 2, length))
        # Bass on the root.
        root = chord[0][:-1] + str(int(chord[0][-1]) - 1)
        out = mix(out, place(tone(note(root), beat * 3.8, pad_vol * 1.2, bass_shape, release=0.2), at, length))
    lead = seq(melody, beat, lead_shape, lead_vol, length)
    return mix(out, lead)


def main(out):
    sfx = os.path.join(out, "sounds", "sfx")
    bgm = os.path.join(out, "sounds", "bgm")
    write(os.path.join(sfx, "correct.wav"), mix(tone(note("E6"), 0.12, 0.5, "bell"), place(tone(note("A6"), 0.35, 0.5, "bell", release=0.25), 0.1, int(0.45 * RATE))))
    write(os.path.join(sfx, "wrong.wav"), mix(tone(110, 0.35, 0.35, "square", release=0.1), tone(116, 0.35, 0.3, "square", release=0.1)))
    write(os.path.join(sfx, "click.wav"), tone(1800, 0.03, 0.4, "sine", attack=0.001, release=0.02))
    pop_n = int(0.08 * RATE)
    write(os.path.join(sfx, "pop.wav"), [math.sin(2 * math.pi * (500 + 1200 * i / pop_n) * i / RATE) * 0.5 * (1 - i / pop_n) for i in range(pop_n)])
    write(os.path.join(sfx, "fanfare.wav"), seq([("C5", 1), ("E5", 1), ("G5", 1), ("C6", 3)], 0.12, "square", 0.3))
    write(os.path.join(sfx, "chime.wav"), mix(*[place(tone(note(n), 0.8, 0.35, "bell", release=0.6), i * 0.15, int(1.4 * RATE)) for i, n in enumerate(["G5", "B5", "D6", "G6"])]))
    write(os.path.join(sfx, "alarm.wav"), mix(*[place(tone(880, 0.12, 0.4, "square", release=0.02), i * 0.25, int(1.0 * RATE)) for i in range(4)]))
    # Background music: 8-bar loops.
    write(os.path.join(bgm, "calm.wav"), loop_bgm(
        [["C4", "E4", "G4", "B4"], ["A3", "C4", "E4", "G4"], ["F3", "A3", "C4", "E4"], ["G3", "B3", "D4", "F4"]],
        [("E5", 2), ("G5", 2), ("A5", 3), (None, 1), ("G5", 2), ("E5", 2), ("D5", 4), ("C5", 2), ("D5", 2), ("E5", 3), (None, 1), ("D5", 2), ("C5", 2), ("C5", 4)],
        0.5, "sine", "sine", 0.12, 0.18, 8))
    write(os.path.join(bgm, "adventure.wav"), loop_bgm(
        [["A3", "C4", "E4"], ["F3", "A3", "C4"], ["C4", "E4", "G4"], ["G3", "B3", "D4"]],
        [("A4", 1), ("C5", 1), ("E5", 2), ("D5", 1), ("C5", 1), ("A4", 2), ("F4", 1), ("A4", 1), ("C5", 2), ("B4", 2), (None, 2),
         ("E5", 1), ("E5", 1), ("G5", 2), ("F5", 1), ("E5", 1), ("C5", 2), ("D5", 2), ("B4", 2), ("A4", 4)],
        0.3, "tri", "square", 0.1, 0.12, 8))
    write(os.path.join(bgm, "tense.wav"), loop_bgm(
        [["E3", "G3", "B3"], ["E3", "G3", "C4"], ["D#3", "F#3", "B3"], ["E3", "G3", "B3"]],
        [("B4", 0.5), (None, 0.5), ("B4", 0.5), ("C5", 0.5), ("B4", 1), (None, 1)] * 8,
        0.22, "square", "tri", 0.09, 0.14, 8))
    for root, _, files in os.walk(os.path.join(out, "sounds")):
        for f in sorted(files):
            p = os.path.join(root, f)
            print(os.path.relpath(p, out), os.path.getsize(p))


if __name__ == "__main__":
    main(sys.argv[1])
