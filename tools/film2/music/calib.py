"""The listening calibration set for film 2's music: three synthesized tracks whose answers are known.

  python3 -I tools/film2/music/calib.py OUTDIR        (writes cal-pos.mp3, cal-neg.mp3, cal-glitch.mp3 and calib.json there and here)

(film 1's calib.py, rebuilt in film 2's own shape: 120 BPM, a sparse opening, a ONE-bar break and the drop right after it.)
listen.py asks the ear film 2's seven questions (voice, glitches, energy, sparse opening, break and when, drop and when, hard
end). An ear is trusted on a question only if it answers that question right on a track where the answer is known, in both
calls:
  cal-pos  120 BPM, 51 s, no voice. 0-10 s a sparse opening (a detuned bell motif and soft ticks, no drums), 10-16 s closed hats
           enter, 16-30 s a build (a rising pluck arpeggio under an opening filter, bass, the kick from 24 s), a ONE-bar
           stop-time break at 30.0-32.0 s (silence), the drop at 32.0 s (full groove plus a supersaw arpeggio, sub and wide
           stabs), and one hard hit at 48.0 s with a short tail. Truth: sparse_open true, break true @ 30.0, drop true @ 32.0,
           hard_end true, voice false.
  cal-neg  the full groove from the first beat, steady for 51 s, no break, no riser and no drop; a spoken English sentence runs
           over it from 8 s and again from 24 s (macOS `say`); the last 4 s fade out. Truth: sparse_open false, break false,
           drop false, hard_end false, voice true.
  cal-glitch  the steady groove with artefacts and no voice: six 150 ms digital dropouts, five full-scale clicks and two
           stutters (a 90 ms slice repeated 7 times). Truth: glitches "minor" or "major", the rest as cal-neg. With
           cal-pos (glitches "none") it calibrates the glitch question, which the pair alone cannot.
Everything is numpy, seeded, and the spoken words are plain (no lyric, no song). The truth lands in calib.json beside the
script, which listen.py reads.
"""
import json, shutil, subprocess, sys, wave
from pathlib import Path

import numpy as np

SR = 44100
BPM = 120
B = 60 / BPM
BAR = 4 * B
rng = np.random.default_rng(7)


def t_of(n):
    return np.arange(int(n * SR)) / SR


def fft_filter(x, lo=None, hi=None):
    """Brick-wall band-pass by FFT: enough for noise shaping here."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    if lo is not None:
        X[f < lo] = 0
    if hi is not None:
        X[f > hi] = 0
    return np.fft.irfft(X, len(x))


def put(buf, at, sig, gain=1.0):
    i = int(at * SR)
    if i >= len(buf):
        return
    sig = sig[:len(buf) - i]
    buf[i:i + len(sig)] += gain * sig


def kick():
    t = t_of(0.28)
    f = 45 + 90 * np.exp(-t * 28)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)


def clap():
    t = t_of(0.22)
    return fft_filter(rng.standard_normal(len(t)), 900, 7000) * np.exp(-t * 22) * 0.6


def hat():
    t = t_of(0.07)
    return fft_filter(rng.standard_normal(len(t)), 7000, 16000) * np.exp(-t * 60) * 0.35


def saw(freq, dur, detune=(0.0,)):
    t = t_of(dur)
    out = np.zeros(len(t))
    for d in detune:
        out += ((t * freq * (1 + d)) % 1.0) * 2 - 1
    return out / len(detune)


def bass_note(freq, dur):
    t = t_of(dur)
    s = np.sin(2 * np.pi * freq * t) + 0.45 * np.sin(2 * np.pi * 2 * freq * t) + 0.2 * np.sin(2 * np.pi * 3 * freq * t)
    return s * np.minimum(1, t * 400) * np.exp(-t * 3.0) * 0.8


def stab(freqs, dur=0.34):
    t = t_of(dur)
    s = sum(saw(f, dur, (-0.004, 0.0, 0.004)) for f in freqs) / len(freqs)
    return fft_filter(s, None, 3200) * np.exp(-t * 9) * np.minimum(1, t * 600)


def groove(buf, a, b, level=1.0, duck=None):
    """Drums, bass and stabs from second a to b on the beat grid (bars of 4/4 at 120 BPM)."""
    nb = int(round((b - a) / B))
    bass_cycle = [55.0, 55.0, 65.4, 55.0, 55.0, 49.0, 55.0, 41.2]        # A1 A1 C2 A1 A1 G1 A1 E1, an eighth each
    for i in range(nb):
        t0 = a + i * B
        put(buf, t0, kick(), 1.0 * level)
        put(buf, t0 + B / 2, hat(), level)
        if i % 4 in (1, 3):
            put(buf, t0, clap(), level)
        put(buf, t0, bass_note(bass_cycle[(2 * i) % 8], B / 2 * 0.9), 0.9 * level)
        put(buf, t0 + B / 2, bass_note(bass_cycle[(2 * i + 1) % 8], B / 2 * 0.9), 0.9 * level)
        if i % 4 in (0, 2):
            put(buf, t0 + (B / 2 if i % 4 == 2 else 0), stab([220.0, 261.6, 329.6]), 0.55 * level)


def big(buf, a, b):
    """The drop's extra layers: sub, a supersaw arpeggio in sixteenths, and a wider stab."""
    nb = int(round((b - a) / B))
    arp = [440.0, 523.3, 659.3, 783.99]
    for i in range(nb):
        t0 = a + i * B
        for k in range(4):
            put(buf, t0 + k * B / 4, stab([arp[(k + i) % 4]], 0.2), 0.7)
        t = t_of(B)
        put(buf, t0, np.sin(2 * np.pi * 41.2 * t) * np.minimum(1, t * 200) * np.minimum(1, (B - t) * 200) * 0.7, 1.0)
        if i % 4 == 0:
            put(buf, t0, stab([110.0, 164.8, 220.0, 261.6, 329.6], 0.9), 0.7)


def bell(freq, dur=1.3):
    """A detuned inharmonic bell: three partials, the upper two off the harmonic series."""
    t = t_of(dur)
    s = (np.sin(2 * np.pi * freq * t) + 0.5 * np.sin(2 * np.pi * freq * 2.76 * t) + 0.3 * np.sin(2 * np.pi * freq * 5.4 * t))
    return s * np.minimum(1, t * 800) * np.exp(-t * 4.0) * 0.5


def tick():
    t = t_of(0.04)
    return np.sin(2 * np.pi * 1800 * t) * np.exp(-t * 110) * 0.3


def arp_note(freq, cutoff):
    t = t_of(0.2)
    return fft_filter(saw(freq, 0.2, (-0.003, 0.003)), None, cutoff) * np.exp(-t * 14) * np.minimum(1, t * 600)


def render_pos():
    """Film 2's shape at 120 BPM: drift 0-10 s, pulse 10-16 s, build 16-30 s (kick from 24 s), a one-bar silence 30-32 s, the
    drop at 32 s, the groove to 48 s, one hard hit at 48 s."""
    total = 51.0
    buf = np.zeros(int(total * SR))
    drop, end_hit = 16 * BAR, 24 * BAR                    # 32.0 s, 48.0 s
    motif = [220.0, 261.6 * 1.012, 207.7, 246.9 * 0.988]       # a slightly out-of-tune minor figure
    nbeat = int(30.0 / B)
    for i in range(nbeat):                                 # 0-30 s, beat by beat
        t0 = i * B
        sec = t0
        if sec < 16.0 and i % 4 in (0, 3):                 # the bell motif until the build takes over
            put(buf, t0, bell(motif[(i // 4 + i % 4) % 4]), 1.0)
        put(buf, t0, tick(), 1.0 if sec < 10 else 0.6)
        if sec >= 10.0:                                    # LOG: closed hats on the eighths
            put(buf, t0, hat(), 0.8)
            put(buf, t0 + B / 2, hat(), 0.8)
        if sec >= 16.0:                                    # CLAUDE: a rising arpeggio under an opening filter, bass, kick
            prog = (sec - 16.0) / 14.0
            for k in range(4):
                f = [220.0, 261.6, 329.6, 392.0][k] * 2 ** ((sec - 16.0) / 14.0 * 7 / 12)
                put(buf, t0 + k * B / 4, arp_note(f, 700 + 5500 * prog), 0.3 + 0.5 * prog)
            put(buf, t0, bass_note(55.0, B * 0.9), 0.5 + 0.4 * prog)
        if sec >= 24.0:
            put(buf, t0, kick(), 0.9)
    # 30.0-32.0 s: the one-bar stop-time break: nothing is placed
    groove(buf, drop, end_hit)
    big(buf, drop, end_hit)
    put(buf, drop, kick(), 1.4)                           # the drop's own impact
    put(buf, end_hit, kick(), 1.6)
    put(buf, end_hit, stab([110.0, 164.8, 220.0, 261.6, 329.6], 1.4), 1.0)
    t = t_of(2.2)
    put(buf, end_hit, fft_filter(rng.standard_normal(len(t)), 2500, 15000) * np.exp(-t * 3.2), 0.9)
    return buf


def render_neg0():
    """The steady groove, no voice yet, fading out over the last 4 s."""
    total = 51.0
    buf = np.zeros(int(total * SR))
    groove(buf, 0, total - B)             # steady groove to the end
    fade_a = total - 4.0
    i = int(fade_a * SR)
    buf[i:] *= np.linspace(1, 0, len(buf) - i)
    return buf


def render_glitch():
    """The steady groove with artefacts a listener should catch: dropouts, clicks and a stutter that repeats a slice."""
    buf = render_neg0()
    for at in (5.1, 11.7, 17.9, 24.2, 30.6, 35.3):                       # 150 ms of digital silence
        i = int(at * SR)
        buf[i:i + int(0.15 * SR)] = 0.0
    for at in (8.3, 14.4, 21.0, 27.8, 33.1):                              # full-scale clicks
        i = int(at * SR)
        buf[i:i + 3] += np.array([1.0, -1.0, 0.8]) * np.abs(buf).max()
    for at in (19.4, 31.9):                                                # a 90 ms slice repeated 7 times
        i, n = int(at * SR), int(0.09 * SR)
        sl = buf[i:i + n].copy()
        for r in range(7):
            buf[i + r * n:i + (r + 1) * n] = sl
    return buf


def say(text, path):
    try:
        subprocess.run(["say", "-v", "Samantha", "-o", str(path), text], check=True, capture_output=True)
    except subprocess.CalledProcessError:       # no such voice on this Mac: the system voice speaks the same words
        subprocess.run(["say", "-o", str(path), text], check=True)


def read_wave(path, ffmpeg):
    raw = subprocess.run([ffmpeg, "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def write_mp3(x, path, ffmpeg):
    x = x / max(1e-9, np.abs(x).max()) * 0.89
    wav = Path(str(path) + ".wav")
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())
    subprocess.run([ffmpeg, "-v", "error", "-y", "-i", str(wav), "-b:a", "192k", str(path)], check=True)
    wav.unlink()


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    ff = shutil.which("ffmpeg")
    pos, neg, gl = render_pos(), render_neg0(), render_glitch()
    # the spoken sentences, mixed in after the groove is rendered
    for k, (at, text) in enumerate([(8.0, "Please keep your hands inside the car until the ride has come to a complete stop."),
                                    (24.0, "Thank you for visiting the museum, and please return the headset at the door.")]):
        s = out / f"say-{k}.aiff"
        say(text, s)
        v = read_wave(s, ff)
        v = v / max(1e-9, np.abs(v).max()) * 0.9 * np.abs(neg).max()
        put(neg, at, v)
        s.unlink()
    write_mp3(pos, out / "cal-pos.mp3", ff)
    write_mp3(neg, out / "cal-neg.mp3", ff)
    write_mp3(gl, out / "cal-glitch.mp3", ff)
    truth = {"cal-pos.mp3": {"voice": False, "sparse_open": True, "break": True, "break_s": round(15 * BAR, 2), "drop": True,
                             "drop_s": round(16 * BAR, 2), "hard_end": True, "glitches": ["none"]},
             "cal-neg.mp3": {"voice": True, "sparse_open": False, "break": False, "break_s": None, "drop": False,
                             "drop_s": None, "hard_end": False, "glitches": ["none"]},
             "cal-glitch.mp3": {"voice": False, "sparse_open": False, "break": False, "break_s": None, "drop": False,
                                "drop_s": None, "hard_end": False, "glitches": ["minor", "major"]}}
    for dst in (out / "calib.json", Path(__file__).resolve().parent / "calib.json"):
        dst.write_text(json.dumps(truth, indent=1) + "\n")
    print(json.dumps(truth))


if __name__ == "__main__":
    main()
