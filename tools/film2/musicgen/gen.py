"""Generate the Mwoyeo film 2's music candidates with ACE-Step 1.5 (rig-log release-034's gen.py, plus --prompts).

  .venv/bin/python ~/musicgen/film2/gen.py OUTDIR --device mps [--dit acestep-v15-turbo] [--lm acestep-5Hz-lm-1.7B]
      [--backend mlx] [--torch-dit] [--vae torch] [--timeout 1800] [--steps 8] [--shift 3.0] [--batch 2] [--seeds 8] [--duration 64] [--only shout,bop] [--prompts FILE]

Run from <root>/src (root: $MUSICGEN_ROOT, default ~/musicgen) under run.sh. Each prompt of --prompts (default
<root>/prompts.json, which on the box is release-034's, so the film passes its own file) gets --seeds clips with fixed seeds (1001.. per prompt), instrumental, its own BPM, 4/4. Writes
OUTDIR/<id>-s<seed>.flac and OUTDIR/manifest.tsv (prompt, seed, bpm asked, seconds, wall per batch, peak memory), one
row per clip. On cuda the device must be the RTX A6000 (run.sh pins it).
"""
import argparse, gc, json, os, shutil, sys, time
from pathlib import Path

import torch

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--device", default="mps", choices=["mps", "cuda"])
ap.add_argument("--dit", default="acestep-v15-turbo")
ap.add_argument("--lm", default="acestep-5Hz-lm-1.7B")      # none: the DiT alone, no LM plan
ap.add_argument("--backend", default="mlx", choices=["mlx", "pt", "vllm"])
# On MPS ACE-Step loads the DiT in float32 (~8 GB) and builds its MLX DiT as a float32 copy of it. The MLX one runs
# (torch on MPS took over 600 s for two 64 s clips), and the torch one is dropped once the copy is built.
ap.add_argument("--torch-dit", action="store_true")
# The MLX VAE decodes 512 latent frames a chunk: +13 GB for a 64 s clip, which took a shared 32 GB host to critical
# memory pressure. The torch VAE decodes 32 a chunk on MPS.
ap.add_argument("--vae", default="torch", choices=["torch", "mlx"])
ap.add_argument("--timeout", type=int, default=1800)    # seconds a generate_music call may take (ACE-Step: 600)
ap.add_argument("--steps", type=int, default=8)
ap.add_argument("--shift", type=float, default=3.0)
ap.add_argument("--guidance", type=float, default=7.0)
ap.add_argument("--batch", type=int, default=2)
ap.add_argument("--seeds", type=int, default=8)
ap.add_argument("--duration", type=float, default=64.0)
ap.add_argument("--only", default="")
ap.add_argument("--prompts", default="")     # the prompts file; empty: <root>/prompts.json
a = ap.parse_args()

if a.device == "cuda" and "A6000" not in torch.cuda.get_device_name(0):
    sys.exit(f"gen.py: device 0 is {torch.cuda.get_device_name(0)}, not the RTX A6000 (run.sh pins it)")
if a.device == "mps" and not torch.backends.mps.is_available():
    sys.exit("gen.py: no MPS device")
out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
R = Path(os.environ.get("MUSICGEN_ROOT", Path.home() / "musicgen"))
prompts = json.loads((Path(a.prompts) if a.prompts else R / "prompts.json").read_text())
if a.only:
    prompts = [p for p in prompts if p["id"] in a.only.split(",")]


def peak_gib():
    """The largest of the allocators' peaks this batch: torch's (cuda, or the MPS driver's current) and MLX's."""
    vals = []
    if a.device == "cuda":
        vals.append(torch.cuda.max_memory_allocated())
    else:
        vals.append(torch.mps.driver_allocated_memory())
        try:
            import mlx.core as mx
            vals.append(mx.get_peak_memory())
            mx.reset_peak_memory()
        except (ImportError, AttributeError):
            pass
    return max(vals) / 2**30


from acestep.handler import AceStepHandler            # noqa: E402
from acestep.llm_inference import LLMHandler          # noqa: E402
from acestep.inference import GenerationParams, GenerationConfig, generate_music   # noqa: E402
import acestep.core.generation.handler.generate_music_execute as gme               # noqa: E402

t0 = time.time()
mlx_dit = a.device == "mps" and not a.torch_dit      # MLX is Apple's; cuda runs the torch DiT
dit = AceStepHandler()
msg, ok = dit.initialize_service(project_root=str(R / "src"), config_path=a.dit, device=a.device,
                                 offload_to_cpu=False, prefer_source="huggingface", use_mlx_dit=mlx_dit)
if not ok:
    sys.exit(f"gen.py: DiT init failed: {msg}")
if mlx_dit:
    if getattr(dit, "mlx_decoder", None) is None:
        sys.exit("gen.py: the MLX DiT did not initialize (see the log); --torch-dit runs the torch one")
    dit.model.decoder.to("meta")      # frees its storage; a later use of the torch decoder fails by name
if a.device == "mps" and a.vae == "torch":
    dit.use_mlx_vae, dit.mlx_vae = False, None
if a.device == "mps":
    gc.collect()
    torch.mps.empty_cache()
gme._DEFAULT_GENERATION_TIMEOUT = a.timeout
lm = None
if a.lm != "none":
    lm = LLMHandler()
    msg, ok = lm.initialize(checkpoint_dir=str(R / "src/checkpoints"), lm_model_path=a.lm, backend=a.backend,
                            device=a.device)
    if not ok:
        sys.exit(f"gen.py: LM init failed: {msg}")
print(f"load {time.time() - t0:.1f} s, {a.dit} ({'mlx' if mlx_dit else 'torch'}) + {a.lm} ({a.backend}) on "
      f"{a.device}, VAE {a.vae}, {a.steps} steps", flush=True)

rows = ["prompt\tseed\tbpm\tduration_s\tbatch_wall_s\tpeak_gib\tfile"]
for p in prompts:
    seeds = [1001 + i for i in range(a.seeds)]
    for b in range(0, len(seeds), a.batch):
        chunk = seeds[b:b + a.batch]
        if a.device == "cuda":
            torch.cuda.reset_peak_memory_stats()
        t1 = time.time()
        params = GenerationParams(caption=p["caption"], lyrics="[Instrumental]", instrumental=True, bpm=p["bpm"],
                                  timesignature="4", duration=a.duration, inference_steps=a.steps, shift=a.shift,
                                  guidance_scale=a.guidance, thinking=lm is not None, use_cot_caption=False)
        config = GenerationConfig(batch_size=len(chunk), allow_lm_batch=True, use_random_seed=False, seeds=chunk,
                                  audio_format="flac")
        res = generate_music(dit, lm, params, config, save_dir=str(out / "raw"))
        wall = time.time() - t1
        if not res.success:
            sys.exit(f"gen.py: {p['id']} seeds {chunk}: {res.error}")
        peak = peak_gib()
        for au in res.audios:
            seed = int(au["params"]["seed"])
            dst = out / f"{p['id']}-s{seed}.flac"
            shutil.copyfile(au["path"], dst)
            rows.append(f"{p['id']}\t{seed}\t{p['bpm']}\t{a.duration}\t{wall:.1f}\t{peak:.1f}\t{dst.name}")
        print(f"{p['id']} seeds {chunk[0]}..{chunk[-1]}: {wall:.1f} s ({wall / len(chunk):.1f} s a clip), "
              f"peak {peak:.1f} GiB", flush=True)
        (out / "manifest.tsv").write_text("\n".join(rows) + "\n")
print(f"total {time.time() - t0:.1f} s, {len(rows) - 1} clips", flush=True)
