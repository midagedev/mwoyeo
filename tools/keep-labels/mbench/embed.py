#!/usr/bin/env python3
"""Sentence / word embeddings for the embedding judges, cached per model as {string: float32 vector} (MB_SCRATCH/cache/emb-<model>.pkl).
Models (weights only in MB_SCRATCH/hf, never in the repo):
  potion   minishlab/potion-multilingual-128M   static embedding (model2vec), MIT        256-d
  e5       intfloat/multilingual-e5-small       12-layer encoder, MIT, "query: " prefix   384-d, max 128 tokens
  eg2      google/embeddinggemma-2              EmbeddingGemma 2, Apache 2.0, text backbone only (vision / audio configs None), float32, 768-d (Matryoshka cuts by slicing
                                                 and re-normalising), prompt "task: classification | query: "
  (EmbeddingGemma 1, google/embeddinggemma-300m, is gated (Gemma terms, manual approval): not downloaded; addendum A-EG2 replaces it by EG2)
CPU only, never the GPU / MPS / ANE."""
import os, pickle, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np
import data

os.environ.setdefault('HF_HOME', f'{data.SCRATCH}/hf')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
REPOS = {'potion': 'minishlab/potion-multilingual-128M', 'e5': 'intfloat/multilingual-e5-small', 'eg2': 'google/embeddinggemma-2',
         'e5-int8': 'intfloat/multilingual-e5-small', 'eg2-int8': 'google/embeddinggemma-2'}      # -int8: the same weights, every Linear dynamically quantised to int8 (torch, CPU)
E5_MAX = 128


def snapshot(name):
    """The cached snapshot directory of the model (downloaded once into MB_SCRATCH/hf)."""
    import glob
    hits = sorted(glob.glob(f'{os.environ["HF_HOME"]}/hub/models--{REPOS[name].replace("/", "--")}/snapshots/*'))
    if not hits:
        from huggingface_hub import snapshot_download
        return snapshot_download(REPOS[name])
    return hits[-1]


class Embedder:
    def __init__(self, name, threads=None):
        self.name = name
        import torch
        if threads: torch.set_num_threads(threads)
        t = time.perf_counter()
        base = name.replace('-int8', '')
        if name == 'potion':
            from model2vec import StaticModel
            self.m = StaticModel.from_pretrained(snapshot(name))
        elif base == 'e5':
            from sentence_transformers import SentenceTransformer
            self.m = SentenceTransformer(snapshot(name), device='cpu')
            self.m.max_seq_length = E5_MAX
        elif base == 'eg2':
            from sentence_transformers import SentenceTransformer
            self.m = SentenceTransformer(snapshot(name), device='cpu', config_kwargs={'vision_config': None, 'audio_config': None},
                                         model_kwargs={'torch_dtype': torch.float32})
            self.m.max_seq_length = E5_MAX
        else:
            raise SystemExit(f'embedder {name}: unknown')
        if name.endswith('-int8'):
            torch.backends.quantized.engine = 'qnnpack'
            self.m = torch.quantization.quantize_dynamic(self.m, {torch.nn.Linear}, dtype=torch.qint8)
        self.load_s = time.perf_counter() - t

    def encode(self, texts, batch_size=32):
        if self.name == 'potion':
            return np.asarray(self.m.encode(list(texts)), dtype=np.float32)
        pre = 'task: classification | query: ' if self.name.startswith('eg2') else 'query: '
        v = self.m.encode([pre + t for t in texts], batch_size=batch_size, normalize_embeddings=True, convert_to_numpy=True, show_progress_bar=False)
        return v.astype(np.float32)


def cache_path(name):
    return f'{data.SCRATCH}/cache/emb-{name}.pkl'


def lookup(name, strings, emb=None):
    """-> (n, d) matrix for `strings`, computing and caching the vectors that are missing."""
    p = cache_path(name)
    store = pickle.load(open(p, 'rb')) if os.path.exists(p) else {}
    todo = sorted({s for s in strings if s not in store}, key=len)
    if todo:
        emb = emb or Embedder(name)
        t = time.perf_counter()
        for i in range(0, len(todo), 512):
            chunk = todo[i:i + 512]
            for s, v in zip(chunk, emb.encode(chunk)): store[s] = v
            print(f'  embed {name}: {min(i + 512, len(todo))}/{len(todo)} ({time.perf_counter() - t:.0f} s)', flush=True)
        pickle.dump(store, open(p, 'wb'))
    return np.stack([store[s] for s in strings]) if strings else np.zeros((0, 1), dtype=np.float32)


def all_strings():
    import dataset
    d = dataset.load()
    texts, toks = set(), set()
    for v in d.values():
        texts.update(b['text'] for b in v['blocks'])
        toks.update(v['tok']['text'])
    return sorted(texts), sorted(toks)


if __name__ == '__main__':
    names = sys.argv[1:] or ['potion', 'e5', 'eg2']
    texts, toks = all_strings()
    for n in names:
        t = time.perf_counter()
        e = Embedder(n)
        lookup(n, texts, e); lookup(n, toks, e)
        print(f'{n}: {len(texts)} block texts + {len(toks)} words embedded in {time.perf_counter() - t:.0f} s (load {e.load_s:.1f} s)')
