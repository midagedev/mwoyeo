"""Measure the beat grid of each candidate track from its mp3 -> beats.json (rig-log release-034's beats.py for the film).

  BEATS_PRIOR=124 BEATS_RANGE=99-155 BEATS_DROP_WIN=8 python3 beats.py raw/glyph-s1001.mp3 ...
      (a generated track: the prior is the BPM its prompt asked for, the range is 0.8x..1.25x of it, as screen.py reads
      it; the drop window as the comment at DROP_WIN says; measure.sh runs the three prompts)

Each run adds or replaces its files' rows in beats.json and keeps the others.

The film cannot be listened to while it is built, so the music is picked and timed by measurement. For each mp3:
  1. decode to mono 22,050 Hz with ffmpeg;
  2. onset envelope: log-compressed STFT magnitude (2048-sample Hann window, 256-sample hop = 11.6 ms), positive
     spectral flux summed over all bins (full) and over 30-150 Hz (low: the kick), each minus its 0.5 s moving mean;
  3. tempo: autocorrelation of the full envelope over 80-170 BPM under a log-normal prior centred on 120 BPM
     (one octave wide), then the period refined by a fine search (±2 %, 0.05 ms steps) that maximises the folded
     comb score sum_k env(phase + k*period) over the whole track, best phase taken per period;
  4. the phase from the kick: the same comb over the low envelope at that period (the full envelope's best phase can
     sit on the off-beat hats, half a beat away); a constant grid, since electronic stock music is made at one tempo,
     and the fit says how well it holds (step 6);
  5. bars and the drop: loudness per beat (RMS dB); the drop is the beat where the 16-beat mean after it rises most
     over the 16-beat mean before it, searched from 6 s to 80 s (BEATS_DROP_WIN, BEATS_DROP_FROM change both); its
     index mod 4 sets which beat opens a bar;
  5b. onset density per beat (`onset_beat`: the mean full-band onset envelope of step 2 in the beat), film 2's measure of a thin
     opening: loudness cannot tell a quiet arpeggio from a sparse bell;
  6. quality: of the 40 strongest kick onsets (local maxima of the low envelope), the share within one film frame
     (1/60 s) of a grid beat, and the median distance; a grid that drifts fails here by number.
Every film cut and slam is taken from these numbers (make_data.py), so swapping the track re-times the film.
"""
import json, os, shutil, subprocess, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
FF = shutil.which("ffmpeg")
SR, NFFT, HOP = 22050, 2048, 256
# The drop search: the window (beats) each side of a candidate and the earliest second it may sit at. The film's clips
# are 64 s and its drop sits at ~35 s, so it reads them with BEATS_DROP_WIN=8 and the default earliest second.
DROP_WIN = int(os.environ.get("BEATS_DROP_WIN", 16))
DROP_FROM = float(os.environ.get("BEATS_DROP_FROM", 6))
DT = HOP / SR
FRAME = 1 / 60
CATALOGUE = {}      # release-034 listed Mixkit tracks here; the film uses generated ones only


def decode(path):
    raw = subprocess.run([FF, "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def envelopes(x):
    n = 1 + (len(x) - NFFT) // HOP
    fr = np.lib.stride_tricks.sliding_window_view(x, NFFT)[::HOP][:n]
    L = np.log1p(100 * np.abs(np.fft.rfft(fr * np.hanning(NFFT), axis=1))).astype(np.float32)
    f = np.fft.rfftfreq(NFFT, 1 / SR)
    flux = np.maximum(0, np.diff(L, axis=0))
    t = (np.arange(1, n) * HOP + NFFT / 2) / SR            # flux[k] lands at frame k+1's centre
    k = int(round(.5 / DT))
    def norm(e):
        e = e - np.convolve(e, np.ones(k) / k, "same")
        return np.maximum(0, e)
    rms = np.sqrt((fr[1:] ** 2).mean(1))
    return t, norm(flux.sum(1)), norm(flux[:, (f >= 30) & (f <= 150)].sum(1)), rms


def comb(t, env, period, phases):
    k = np.arange(int((t[-1] - phases.max()) / period))
    return np.interp(phases[:, None] + period * k[None, :], t, env).sum(1)


def measure(path, prior=120.0, lo=80.0, hi=170.0):
    x = decode(path)
    t, env, low, rms = envelopes(x)
    e = env - env.mean()
    ac = np.correlate(e, e, "full")[len(e) - 1:] / np.arange(len(e), 0, -1)
    lags = np.arange(len(ac)) * DT
    ok = (lags >= 60 / hi) & (lags <= 60 / lo)
    bpm = 60 / np.where(ok, lags, 1)
    score = np.where(ok, ac * np.exp(-.5 * np.log2(bpm / prior) ** 2), -np.inf)
    p0 = lags[int(np.argmax(score))]
    best = (-1, 0, 0)
    for p in np.arange(p0 * .98, p0 * 1.02, 5e-5):
        ph = np.arange(0, p, 1e-3)
        c = comb(t, env, p, ph)
        i = int(np.argmax(c))
        if c[i] > best[0]: best = (c[i], p, ph[i])
    _, period, _ = best
    ph = np.arange(0, period, 2.5e-4)
    phase = float(ph[int(np.argmax(comb(t, low, period, ph)))])
    nb = int((t[-1] - phase) / period)
    beats = phase + period * np.arange(nb)
    # loudness per beat
    db = np.array([20 * np.log10(rms[(t >= b) & (t < b + period)].mean() + 1e-9) for b in beats])
    # onset density per beat: the mean full-band onset envelope (step 2) in the beat. Level-independent (the spectrum is
    # log-compressed), so a quiet arpeggio and a loud one count alike: film 2's DRIFT must be thin, not only quiet.
    onset = np.array([env[(t >= b) & (t < b + period)].mean() for b in beats])
    jump = np.full(nb, -np.inf)
    for b in range(DROP_WIN, nb - DROP_WIN):
        if DROP_FROM <= beats[b] <= 80: jump[b] = db[b:b + DROP_WIN].mean() - db[b - DROP_WIN:b].mean()
    drop = int(np.argmax(jump))
    # the strongest rises, at least 8 beats apart (a break's end and the final drop are both rises): the fit reads each
    cand, taken = [], jump.copy()
    for _ in range(4):
        i = int(np.argmax(taken))
        if not np.isfinite(taken[i]): break
        cand.append([i, round(float(jump[i]), 2)])
        taken[max(0, i - 8):i + 8] = -np.inf
    # quality: the strongest kick onsets against the grid
    pk = np.where((low[1:-1] > low[:-2]) & (low[1:-1] >= low[2:]))[0] + 1
    pk = pk[np.argsort(low[pk])[::-1][:40]]
    d = np.abs(((t[pk] - phase + period / 2) % period) - period / 2)
    return {
        "bpm": round(60 / period, 3), "period_s": round(period, 5), "first_beat_s": round(phase, 4),
        "bar_offset": drop % 4, "drop_beat": drop, "drop_s": round(beats[drop], 4), "drop_jump_db": round(jump[drop], 2),
        "rises": cand, "beats": nb, "length_s": round(len(x) / SR, 2),
        "kick_on_grid": f"{(d <= FRAME).sum()}/{len(d)}", "kick_median_ms": round(float(np.median(d)) * 1e3, 1),
        "loud_db": [round(v, 1) for v in db], "onset_beat": [round(float(v), 1) for v in onset],
    }


def main():
    paths = [Path(p) for p in sys.argv[1:]]
    if not paths: sys.exit(__doc__)
    prior = float(os.environ.get("BEATS_PRIOR", 120))
    lo, hi = (float(v) for v in os.environ.get("BEATS_RANGE", "80-170").split("-"))
    if not lo < prior < hi:
        sys.exit(f"beats.py: BEATS_PRIOR {prior} is outside BEATS_RANGE {lo:g}-{hi:g}")
    dst = Path(os.environ.get("BEATS_OUT", HERE / "beats.json"))
    out = json.loads(dst.read_text()) if dst.exists() else {}
    for p in paths:
        m = measure(p, prior, lo, hi)
        if p.stem in CATALOGUE:
            name, artist, genre = CATALOGUE[p.stem]
            url = f"https://assets.mixkit.co/music/{p.stem}/{p.stem}.mp3"
        else:   # a track generated for this film (musicgen/): no catalogue row, no download URL
            name, artist, genre, url = p.stem, "ACE-Step 1.5, generated for this film", "electronic", ""
        out[p.stem] = {"name": name, "artist": artist, "genre": genre, "url": url, "prior_bpm": prior, **m}
        print(f"{p.stem:>5} {name:<20} {m['bpm']:7.2f} BPM  first beat {m['first_beat_s']:.3f} s  drop {m['drop_s']:6.2f} s "
              f"(beat {m['drop_beat']}, +{m['drop_jump_db']} dB)  kick on grid {m['kick_on_grid']}, median {m['kick_median_ms']} ms")
    dst.write_text(json.dumps(out, indent=1) + "\n")


if __name__ == "__main__":
    main()
