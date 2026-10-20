"""Screen the generated music candidates by measurement, before anyone listens.

  python3 musicgen/screen.py OUTDIR            (OUTDIR holds <prompt>-s<seed>.mp3 and gen.py's manifest.tsv)

(rig-log release-034's screen.py. The tempo range is 0.8x..1.25x of the asked BPM, int() of each, where 034 read a fixed
120-210: the film asks for 118, 124 and 128, and measure.sh gives beats.py the same range.)

For each clip: the beat grid (beats.py's measure, its tempo prior at the BPM the prompt asked for, 120-210 BPM), the
strongest kick onsets against that grid (kick_on_grid), and the hit grid: the 40 strongest full-band onsets (the
brass stabs and drum hits a cut would land on), each placed by its phase in the beat (0 on the beat, 0.5 a straight
eighth, ~0.67 a swung eighth). A full-band onset peaks ~20 ms before the low band's (track 201: hits at phase 0.96
and 0.46 of a 0.5 s beat), so a hit counts as on the beat within 0.1 beat. A clip passes the screen when its tempo is
within 3 % of the asked BPM and its pulse sits on the grid's beat: the low band's onset energy peaks within a twelfth of
the beat (pulse). The kick count is read, not gated: it came from a four-on-the-floor track, and a swing drummer's bass
drum accents off the beat (the first generated take: 11 of 40 strongest kicks on the grid, median 90.5 ms off, while
38 % of its low-band onset energy sat within a twelfth of the beat, its largest pair of bins). The hit counts say where
its stabs fall (a film cut lands only on a beat, render.py sync). sound_end_s is the end of its last beat above
-40 dB. Prints one row per clip and writes OUTDIR/screen.tsv.
"""
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent.parent / "music"
sys.path.insert(0, str(HERE))
import beats as B   # noqa: E402


def hits(path, period, phase, n=40):
    t, env, _, _ = B.envelopes(B.decode(path))
    pk = np.where((env[1:-1] > env[:-2]) & (env[1:-1] >= env[2:]))[0] + 1
    pk = pk[np.argsort(env[pk])[::-1][:n]]
    ph = ((t[pk] - phase) / period) % 1.0
    on = np.minimum(ph, 1 - ph) <= .1
    return np.sort(t[pk]), ph, int(on.sum())


def pulse(path, period, phase):
    """Where the pulse sits on the grid: the low band's onset peaks (its loudest tenth), weighted by strength, binned by
    their phase in the beat in twelfths. Returns the share within a twelfth of the beat and whether that pair of bins
    (11 and 0) holds more than any other adjacent pair: the grid's beat is where the bass lands most."""
    t, _, low, _ = B.envelopes(B.decode(path))
    pk = np.where((low[1:-1] > low[:-2]) & (low[1:-1] >= low[2:]))[0] + 1
    pk = pk[low[pk] > np.percentile(low, 90)]
    h, _ = np.histogram(((t[pk] - phase) / period) % 1.0, bins=12, range=(0, 1), weights=low[pk])
    pairs = h + np.roll(h, 1)                    # pairs[i] = bins i-1 and i; pairs[0] straddles the beat
    return pairs[0] / h.sum(), int(np.argmax(pairs)) == 0


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    rows = {}
    for line in (out / "manifest.tsv").read_text().splitlines()[1:]:
        p, seed, bpm, *_ = line.split("\t")
        rows[f"{p}-s{seed}"] = float(bpm)
    table = ["clip\tasked_bpm\tbpm\tpulse_on_beat\tkick_on_grid\thits_on_beat\tswung_hits\tsound_end_s\tdrop_s\tpass"]
    for stem, asked in sorted(rows.items()):
        mp3 = out / f"{stem}.mp3"
        if not mp3.exists():
            sys.exit(f"screen.py: no {mp3} (gen.py wrote {stem}.flac; convert it first)")
        m = B.measure(mp3, asked, int(asked * .8), int(asked * 1.25))
        _, ph, on = hits(mp3, m["period_s"], m["first_beat_s"])
        swung = int(((ph > .6) & (ph < .73)).sum())
        share, peak = pulse(mp3, m["period_s"], m["first_beat_s"])
        loud = [i for i, db in enumerate(m["loud_db"]) if db > -40]
        end = round(m["first_beat_s"] + (loud[-1] + 1) * m["period_s"], 2) if loud else 0.0
        ok = abs(m["bpm"] / asked - 1) <= .03 and peak
        table.append(f"{stem}\t{asked:g}\t{m['bpm']}\t{share:.2f}{'' if peak else ' off'}\t{m['kick_on_grid']}\t"
                     f"{on}/40\t{swung}/40\t{end}\t{m['drop_s']}\t{'pass' if ok else 'fail'}")
        print(table[-1].replace("\t", "  "), flush=True)
    (out / "screen.tsv").write_text("\n".join(table) + "\n")


if __name__ == "__main__":
    main()
