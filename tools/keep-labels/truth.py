"""The translate / keep / either truth of one OCR word, shared by the paper labeller (label.py), the code-case labeller
(code_labels.py) and the report (rules_report.py).

Definition (design note, addendum 2): a word is `keep` when it must appear exactly as written (math, code, commands, paths, URLs,
identifiers, log lines), `translate` when it is prose a reader needs in the target language, and `either` when no harm is done
whichever way the engine goes (numbers, versions or "C++" inside a sentence, names, bare punctuation, text of a drawn figure,
words the glyphs could not decide). `either` words are not scored. A word with no truth at all (nothing under it) has keep ''.
The `reason` rides along for debugging: math, code, cmd, flag, path, url, id, log, prose, name, number, ...; it is never scored.
"""
import re

KEEP, TRANSLATE, EITHER, NONE = 'keep', 'translate', 'either', ''
SCORED = (KEEP, TRANSLATE)

# words that are capitalised inside a sentence without being names
STRUCTURAL = {'table', 'figure', 'fig', 'section', 'appendix', 'equation', 'eq', 'theorem', 'lemma', 'proposition', 'definition',
              'corollary', 'algorithm', 'chapter', 'remark', 'proof', 'example', 'abstract', 'introduction', 'conclusion', 'references',
              'we', 'our', 'the', 'this', 'these', 'in', 'on', 'for', 'to', 'of', 'and', 'with', 'by', 'as', 'at', 'from', 'where', 'here'}
PUNCT = '.,;:!?()[]{}"\'“”‘’'


def core(w):
    return w.strip(PUNCT)


def near_tag(w):
    """Shape of a word that rules mistake for mathematics or code ('' when it has none)."""
    c = core(w)
    if not c: return ''
    if '://' in c or '@' in c or c.startswith('www.'): return 'url'
    if re.fullmatch(r'v?\d+(\.\d+){1,3}(-\w+)?', c): return 'version'
    if re.fullmatch(r'\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}/\d{1,2}/\d{2,4}', c): return 'date'
    if '+' in c or c.endswith('#'): return 'plus'
    if '/' in c and len(c) > 1: return 'slash'
    if re.search(r'\w[-‐‑–]\w', c): return 'hyphen'
    if '_' in c: return 'underscore'
    if re.fullmatch(r'[\d.,]+%?', c) or re.fullmatch(r'\d+(st|nd|rd|th)', c): return 'number'
    if re.fullmatch(r'[A-Z]\.+', w.strip(',;:!?()[]{}"\'“”‘’')): return 'initial'
    if re.fullmatch(r'[A-Za-z]', c): return 'single'
    if re.fullmatch(r'[A-Z][A-Z0-9]{1,}', c) or re.fullmatch(r'[A-Z]+[a-z]?\d+', c): return 'acronym'
    if re.search(r'[a-z][A-Z]', c): return 'camel'
    if re.search(r'\w\.\w', c): return 'dotted'
    if re.search(r'\d', c) and re.search(r'[A-Za-z]', c): return 'alnum'
    return ''


def reason_of(t):
    """Why a piece of code-like text stays as written, from its shape (the notes of a case name the reason when this guess is wrong)."""
    t = t.strip()
    if re.search(r'https?://|www\.|\S@\S+\.\w', t): return 'url'
    if re.fullmatch(r'(?:(?:Ctrl|Cmd|Alt|Shift|Option|Opt|Win|Meta|Control|Command)\+)+\S+', t): return 'hotkey'
    if re.fullmatch(r'[0-9a-f]{7,40}', t) and re.search(r'\d', t) and re.search(r'[a-f]', t): return 'hash'
    if re.match(r'^(\$ |\S+@\S+:\S*[$#] |> )', t) or re.match(r'^(npm|pip|pip3|git|go|make|brew|cd|ls|cargo|docker|curl|python|python3|node|swift|sudo|cat|rm|mv|cp|mkdir|chmod|ssh|yarn|pytest)\s', t): return 'cmd'
    if re.fullmatch(r'-{1,2}[\w-]+([= ]\S+)?', t): return 'flag'
    if re.fullmatch(r'(~|\.{1,2})?/[\w./~-]*|[\w.-]+(/[\w.-]+)+/?', t) or re.fullmatch(r'[\w-]+\.(swift|go|py|js|ts|rs|c|h|cpp|java|md|txt|json|toml|yaml|yml|sh)', t): return 'path'
    if re.fullmatch(r'[A-Za-z]|[α-ωΑ-Ω]', t): return 'math'
    if re.fullmatch(r'[A-Za-z_][\w.]*(\(\))?', t): return 'id'
    return 'code'


def prose_truth(w, tag, first, prev, cjk):
    """(keep, reason) of a word cut from prose (a word of the text face, or of a unit the notes do not keep).
    first: the word opens its block; prev: the previous word of the block (or ''); cjk: the block is prose of a CJK language."""
    c = core(w)
    if not any(ch.isalnum() for ch in w): return EITHER, 'punct'
    if tag == 'url': return KEEP, 'url'
    if tag == 'underscore': return KEEP, 'id'
    if tag == 'slash':
        if re.search(r'\d', c) or c.endswith('/') or c.startswith('/'): return KEEP, 'path'
        if re.fullmatch(r'[a-z]{2,}(/[a-z]{2,})+', c): return TRANSLATE, 'prose'
        return EITHER, 'slash'
    if tag == 'dotted':
        if re.fullmatch(r'(e\.g|i\.e|a\.e|etc|cf|vs|al|resp|viz|p\.p)\.?', c) or re.fullmatch(r'([A-Za-z]\.){2,}', c + '.'): return EITHER, 'abbrev'
        return KEEP, 'id'
    if tag in ('number', 'version', 'date', 'alnum', 'plus'): return EITHER, tag
    if tag in ('acronym', 'camel', 'initial'): return EITHER, 'name'
    if tag == 'single': return (TRANSLATE, 'prose') if c == 'a' else (EITHER, 'single')
    capital = c[:1].isupper() and any(ch.islower() for ch in c) and len(c) >= 2
    sentence_start = first or not prev or prev.rstrip()[-1:] in '.?!:;' or prev.rstrip()[-1:] in '([“"‘' or not any(ch.isalnum() for ch in prev)
    if capital and not sentence_start and c.split('-')[0].lower() not in STRUCTURAL: return EITHER, 'name'
    if tag == 'hyphen':
        if all(len(p) >= 2 and p.isalpha() for p in re.split(r'[-‐‑–]', c)) and not any(p[:1].isupper() for p in re.split(r'[-‐‑–]', c)[1:]): return TRANSLATE, 'prose'
        return EITHER, 'hyphen'
    if cjk and re.fullmatch(r'[\x21-\x7e]+', c): return EITHER, 'latin'          # an unmarked Latin token inside CJK prose: the notes did not keep it
    return TRANSLATE, 'prose'


def keep_runs(keeps):
    """Runs of keep words in the sequence of scored words (either / no-truth words are skipped, so `x ( 1 ) y` stays one run).
    -> list of runs, each a list of raw word indices of its keep words; the scored sequence S is returned too."""
    S = [k for k, v in enumerate(keeps) if v in SCORED]
    runs, cur = [], []
    for k in S:
        if keeps[k] == KEEP: cur.append(k)
        elif cur: runs.append(cur); cur = []
    if cur: runs.append(cur)
    return runs, S


def block_class(keeps):
    """keep (>= 1 keep word, no translate word) | translate | mixed | either (no scored word, some either) | none (no truth at all)."""
    k = sum(1 for v in keeps if v == KEEP); t = sum(1 for v in keeps if v == TRANSLATE); e = sum(1 for v in keeps if v == EITHER)
    if k + t == 0: return 'either' if e else 'none'
    if t == 0: return 'keep'
    if k == 0: return 'translate'
    return 'mixed'
