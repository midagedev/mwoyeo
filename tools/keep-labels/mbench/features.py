#!/usr/bin/env python3
"""Cheap features of a block and of a word for the layout model (judge 2) and for the "+ layout" variants of the embedding judges.

Block features (one row per OCR block, in reading order inside its picture and read): geometry (lines, words, size, indent against the picture's text margin),
monospace pitch from the word boxes (the spread of width / length over ASCII words, the residual of x against the character offset inside a line, the spread of the
line pitch across lines), tint (the block background the app computes, against the frame's dominant colour), the character mix (CJK, hangul, kana, digits, symbols,
underscores, dots, slashes ...), line ends and line starts, keyword hits, word shapes, and the same few features of the previous and next blocks (a code region is cut
into several blocks by the document read) plus their left-edge alignment and vertical gap.
Word features (one row per word of a block): the shape of the word, its box against the block's (pitch per character, height), its background against the block's
(a chip behind an inline code piece), the shapes of the neighbours and a few features of the block.
Nothing here calls Core or truth.py: the features are the model's input, never the rules' output."""
import math, re
import numpy as np

SYM = set('{}()[];=<>/\\|_$#@~^*&%+-:,"\'`!?')
CODE_KW = set('func let var return import class struct enum public private static def const async await guard switch self nil null true false void init extension '
              'protocol throws throw fileprivate internal override final lazy typealias subscript deinit defer elif except raise lambda yield None True False '
              'Int String Bool Double Float Array Dictionary Optional Void Self Any print println printf fn pub mut impl package interface function export import '
              'enum case default break continue where while catch try'.split())
WEAK_KW = set('if else for in is as do this new with from use type any some at to of'.split())
CMD_KW = set('git swift swiftc xcodebuild xcodegen npm node python python3 pip brew docker curl wget ssh scp sudo cd ls cat grep sed awk chmod rm mv cp mkdir echo export '
             'make cargo go just kill ps find tar open defaults codesign security xcrun notarytool plutil jq tee diff head tail sort uniq wc touch which env source '
             'commit push pull merge checkout rebase stash status log add reset clone build test run install'.split())
LOG_KW = set('passed failed error warning Compiling Linking Build Test Suite started finished executed note info debug fatal Executed tests succeeded FAILED PASSED '
             'Warning Error Fatal seconds took ms'.split())
EXT = set('swift py js ts tsx json yml yaml plist xcconfig sh md txt c h m cpp rs go rb xcstrings html css toml lock log pdf png jpg'.split())
HANGUL = re.compile('[가-힣ᄀ-ᇿ]')
KANA = re.compile('[぀-ヿ]')
HAN = re.compile('[一-鿿]')
CJKP = re.compile('[　-〿＀-￯]')
URL = re.compile(r'https?:|www\.|\w+\.(com|org|io|dev|net|app)\b', re.I)
VER = re.compile(r'^v?\d+(\.\d+){1,3}[a-z0-9-]*$')
HEX = re.compile(r'^[0-9a-f]{7,40}$')
NUM = re.compile(r'^[\d.,:%+-]+$')
CAMEL = re.compile(r'[a-z][A-Z]')
LE_CODE = ';{})],:\\'
LE_PROSE = '.!?。！？다요'
COMMENT = ('#', '//', '///', '--', '/*', '*', '<!--', ';')
PROMPT = ('$', '>', '%', '❯', '#!', '>>>')


def ascii_only(s):
    return all(ord(c) < 128 for c in s)


def group_lines(words):
    """The words of a block grouped by baseline as regionfeed does: sort by (centre y, x), a word within 0.6 median heights of the line's first word joins it."""
    if not words: return []
    hs = sorted(w[5] for w in words); h = hs[len(hs) // 2]
    out = []
    for w in sorted(words, key=lambda w: (w[3] + w[5] / 2, w[2])):
        cy = w[3] + w[5] / 2
        if out and abs(cy - out[-1][0]) <= 0.6 * h: out[-1][1].append(w)
        else: out.append([cy, [w]])
    return [sorted(ws, key=lambda w: w[2]) for _, ws in out]


def cv(v):
    v = np.asarray(v, dtype=float)
    return float(v.std() / v.mean()) if len(v) >= 2 and v.mean() > 0 else float('nan')


def lum(rgb):
    return (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255.0


def mono_features(lines):
    """-> (n ascii words >= 3 chars, CV of width/len over them, median pitch / median word height, mean fit residual in chars, CV of line pitch)."""
    pit, hts = [], []
    for ln in lines:
        for w in ln:
            if len(w[6]) >= 3 and ascii_only(w[6]):
                pit.append(w[4] / len(w[6])); hts.append(w[5])
    n = len(pit)
    cvw = cv(pit) if n >= 3 else float('nan')
    rel = float(np.median(pit) / np.median(hts)) if n >= 1 else float('nan')
    res, lp = [], []
    for ln in lines:
        if len(ln) >= 3 and all(ascii_only(w[6]) for w in ln):
            s = np.array([w[0] for w in ln], dtype=float); x = np.array([w[2] for w in ln], dtype=float)
            if np.ptp(s) > 0:
                A = np.vstack([s, np.ones_like(s)]).T
                (p, a), *_ = np.linalg.lstsq(A, x, rcond=None)
                if p > 0: res.append(float(np.sqrt(np.mean((A @ [p, a] - x) ** 2)) / p))
        if len(ln) >= 2 and all(ascii_only(w[6]) for w in ln):
            nch = ln[-1][1] - ln[0][0]
            if nch > 0: lp.append((ln[-1][2] + ln[-1][4] - ln[0][2]) / nch)
    return n, cvw, rel, (float(np.mean(res)) if res else float('nan')), (cv(lp) if len(lp) >= 2 else float('nan'))


OWN = ['nlines', 'nwords', 'lognch', 'medh_rel', 'x_rel', 'y_rel', 'w_rel', 'aspect', 'indent', 'right_gap',
       'm_n', 'm_cv', 'm_pitch', 'm_fit', 'm_linecv',
       'c_dist', 'c_lum', 'c_flum', 'c_dlum',
       't_cjk', 't_hangul', 't_kana', 't_han', 't_letter', 't_digit', 't_sym', 't_upper', 't_under', 't_dotmid', 't_slash', 't_dash', 't_paren', 't_brace', 't_eq',
       't_colon', 't_semi', 't_comma', 't_quote', 't_period',
       'le_code', 'le_prose', 'ls_comment', 'ls_prompt', 'first_digit', 'first_dash', 'last_code', 'last_prose',
       'kw_code', 'kw_weak', 'kw_cmd', 'kw_log',
       'w_camel', 'w_snake', 'w_flag', 'w_path', 'w_url', 'w_ver', 'w_hex', 'w_num', 'w_call', 'w_caps', 'w_ext', 'w_ascii', 'w_avglen', 'w_maxlen', 'w_cjkword',
       'lang_ko', 'lang_ja', 'lang_zh', 'lang_en', 'read_vn']
NB_SEL = ['c_dist', 'm_fit', 'm_pitch', 'm_cv', 't_sym', 't_cjk', 'kw_code', 'kw_cmd', 'le_code', 'indent', 'nlines', 'ls_comment', 'w_path', 't_digit']
BLOCK_NAMES = (OWN + [f'prev_{n}' for n in NB_SEL] + [f'next_{n}' for n in NB_SEL]
               + ['prev_dx', 'next_dx', 'prev_gap', 'next_gap', 'prev_same_bg', 'next_same_bg', 'win2_sym', 'win2_fit', 'win2_cjk', 'win2_code', 'win2_same_bg', 'win2_dx'])
BLOCK_INDEX = {n: i for i, n in enumerate(BLOCK_NAMES)}


def own_features(b, margin):
    """-> dict of OWN for one block."""
    W, H = b['img']
    r = b['ocr']['r']; words = b['ocr']['w']
    lines = group_lines(words)
    medh = float(np.median([w[5] for w in words])) if words else 1.0
    t = b['text']
    nch = max(1, len(t))
    nonsp = [c for c in t if not c.isspace()]
    nn = max(1, len(nonsp))
    f = dict.fromkeys(OWN, float('nan'))
    f.update(nlines=len(lines), nwords=len(words), lognch=math.log(nch), medh_rel=medh / H, x_rel=r[0] / W, y_rel=r[1] / H, w_rel=r[2] / W, aspect=r[2] / max(1.0, r[3]),
             indent=(r[0] - margin) / max(1.0, medh), right_gap=(W - r[0] - r[2]) / W)
    f['m_n'], f['m_cv'], f['m_pitch'], f['m_fit'], f['m_linecv'] = mono_features(lines)
    fd = b['feed']
    if fd:
        bg, fr = fd['bg'], fd['frame']
        f['c_dist'] = math.dist(bg, fr) / 441.7; f['c_lum'] = lum(bg); f['c_flum'] = lum(fr); f['c_dlum'] = lum(bg) - lum(fr)
    cnt = lambda pred: sum(1 for c in nonsp if pred(c)) / nn
    f['t_hangul'] = cnt(lambda c: bool(HANGUL.match(c))); f['t_kana'] = cnt(lambda c: bool(KANA.match(c))); f['t_han'] = cnt(lambda c: bool(HAN.match(c)))
    f['t_cjk'] = f['t_hangul'] + f['t_kana'] + f['t_han'] + cnt(lambda c: bool(CJKP.match(c)))
    f['t_letter'] = cnt(lambda c: c.isascii() and c.isalpha()); f['t_digit'] = cnt(lambda c: c.isdigit()); f['t_sym'] = cnt(lambda c: c in SYM)
    f['t_upper'] = cnt(lambda c: c.isupper()); f['t_under'] = cnt(lambda c: c == '_'); f['t_slash'] = cnt(lambda c: c in '/\\'); f['t_dash'] = cnt(lambda c: c == '-')
    f['t_paren'] = cnt(lambda c: c in '()'); f['t_brace'] = cnt(lambda c: c in '{}[]'); f['t_eq'] = cnt(lambda c: c in '=<>'); f['t_colon'] = cnt(lambda c: c == ':')
    f['t_semi'] = cnt(lambda c: c == ';'); f['t_comma'] = cnt(lambda c: c == ','); f['t_quote'] = cnt(lambda c: c in '"\'`'); f['t_period'] = cnt(lambda c: c in '.。')
    f['t_dotmid'] = len(re.findall(r'\w\.\w', t)) / nn
    # line ends and starts (text of each baseline group)
    texts = []
    for ln in lines:
        texts.append(t[ln[0][0]:ln[-1][1]].strip())
    texts = [x for x in texts if x]
    nl = max(1, len(texts))
    f['le_code'] = sum(1 for x in texts if x[-1] in LE_CODE) / nl
    f['le_prose'] = sum(1 for x in texts if x[-1] in LE_PROSE) / nl
    f['ls_comment'] = sum(1 for x in texts if x.startswith(COMMENT)) / nl
    f['ls_prompt'] = sum(1 for x in texts if x.startswith(PROMPT)) / nl
    f['first_digit'] = float(bool(texts) and texts[0][:1].isdigit()); f['first_dash'] = float(bool(texts) and texts[0][:1] in '-*+•')
    f['last_code'] = float(bool(texts) and texts[-1][-1] in LE_CODE); f['last_prose'] = float(bool(texts) and texts[-1][-1] in LE_PROSE)
    toks = [w[6] for w in words]
    nt = max(1, len(toks))
    strip = lambda s: s.strip('.,;:!?()[]{}"\'`')
    f['kw_code'] = sum(1 for s in toks if strip(s) in CODE_KW) / nt; f['kw_weak'] = sum(1 for s in toks if strip(s) in WEAK_KW) / nt
    f['kw_cmd'] = sum(1 for s in toks if strip(s) in CMD_KW) / nt; f['kw_log'] = sum(1 for s in toks if strip(s) in LOG_KW) / nt
    f['w_camel'] = sum(1 for s in toks if CAMEL.search(s)) / nt; f['w_snake'] = sum(1 for s in toks if re.search(r'[A-Za-z]_[A-Za-z]', s)) / nt
    f['w_flag'] = sum(1 for s in toks if re.match(r'^--?[A-Za-z]', s)) / nt
    f['w_path'] = sum(1 for s in toks if re.search(r'[A-Za-z0-9_.-]/[A-Za-z0-9_.-]', s) or s.startswith(('~/', './', '../', '/'))) / nt
    f['w_url'] = sum(1 for s in toks if URL.search(s)) / nt; f['w_ver'] = sum(1 for s in toks if VER.match(s)) / nt; f['w_hex'] = sum(1 for s in toks if HEX.match(s) and re.search(r'\d', s) and re.search('[a-f]', s)) / nt
    f['w_num'] = sum(1 for s in toks if NUM.match(s)) / nt; f['w_call'] = sum(1 for s in toks if re.search(r'\w\(', s)) / nt
    f['w_caps'] = sum(1 for s in toks if len(s) >= 2 and s.isupper() and s.isalpha()) / nt
    f['w_ext'] = sum(1 for s in toks if '.' in s and s.rsplit('.', 1)[-1].strip(',:;)') in EXT) / nt
    f['w_ascii'] = sum(1 for s in toks if ascii_only(s)) / nt; f['w_avglen'] = float(np.mean([len(s) for s in toks])) if toks else 0.0; f['w_maxlen'] = float(max([len(s) for s in toks] or [0]))
    f['w_cjkword'] = sum(1 for s in toks if not ascii_only(s)) / nt
    lg = b['lang']
    f['lang_ko'] = float(lg == 'ko'); f['lang_ja'] = float(lg == 'ja'); f['lang_zh'] = float(lg.startswith('zh')); f['lang_en'] = float(lg == 'en'); f['read_vn'] = float(b['read'] == 'vn')
    return f


def picture_groups(blocks):
    """Blocks of one picture and read, in OCR order: {(paper, page, read): [block ...]}"""
    g = {}
    for b in blocks:
        g.setdefault((b['set'], b['paper'], b['page'], b['read']), []).append(b)
    for v in g.values(): v.sort(key=lambda b: int(b['id'].rsplit('-', 1)[1]))
    return g


def margin_of(grp):
    """The picture's text margin: the smallest left edge of a block with two or more words (code_features.py's margin)."""
    xs = [b['ocr']['r'][0] for b in grp if len(b['ocr']['w']) >= 2] or [b['ocr']['r'][0] for b in grp]
    return min(xs)


def assemble_row(row, grp, own, k):
    """Fills one block's feature row (len(BLOCK_NAMES)): its own features, the previous / next block's, the gaps, and the window of two blocks each side."""
    ix = BLOCK_INDEX
    b, o = grp[k], own[k]
    for n in OWN: row[ix[n]] = o[n]
    medh = max(1.0, float(np.median([w[5] for w in b['ocr']['w']] or [1.0])))
    for tag, j in (('prev', k - 1), ('next', k + 1)):
        if 0 <= j < len(grp):
            for n in NB_SEL: row[ix[f'{tag}_{n}']] = own[j][n]
            nb = grp[j]
            row[ix[f'{tag}_dx']] = abs(nb['ocr']['r'][0] - b['ocr']['r'][0]) / medh
            gap = (b['ocr']['r'][1] - (nb['ocr']['r'][1] + nb['ocr']['r'][3])) if tag == 'prev' else (nb['ocr']['r'][1] - (b['ocr']['r'][1] + b['ocr']['r'][3]))
            row[ix[f'{tag}_gap']] = gap / medh
            if b['feed'] and nb['feed']: row[ix[f'{tag}_same_bg']] = float(math.dist(b['feed']['bg'], nb['feed']['bg']) < 8)
    win = [j for j in range(k - 2, k + 3) if 0 <= j < len(grp) and j != k]
    if win:
        nm = lambda n: float(np.nanmean([own[j][n] for j in win])) if any(not math.isnan(own[j][n]) for j in win) else float('nan')
        row[ix['win2_sym']] = nm('t_sym'); row[ix['win2_fit']] = nm('m_fit'); row[ix['win2_cjk']] = nm('t_cjk'); row[ix['win2_code']] = nm('kw_code')
        if b['feed']:
            row[ix['win2_same_bg']] = float(np.mean([math.dist(b['feed']['bg'], grp[j]['feed']['bg']) < 8 for j in win if grp[j]['feed']]))
        row[ix['win2_dx']] = float(np.mean([abs(grp[j]['ocr']['r'][0] - b['ocr']['r'][0]) for j in win])) / medh


def group_rows(grp):
    """-> (X (len(grp), len(BLOCK_NAMES)), own dicts) of one picture's read, `grp` in OCR order."""
    margin = margin_of(grp)
    own = [own_features(b, margin) for b in grp]
    X = np.full((len(grp), len(BLOCK_NAMES)), np.nan, dtype=np.float32)
    for k in range(len(grp)): assemble_row(X[k], grp, own, k)
    return X, own


def block_matrix(blocks):
    """-> (X float32 (n, len(BLOCK_NAMES)) in the order of `blocks`, own dicts). Rows are filled group by group; neighbours are the previous and next block of the OCR order."""
    pos = {id(b): i for i, b in enumerate(blocks)}
    X = np.full((len(blocks), len(BLOCK_NAMES)), np.nan, dtype=np.float32)
    own_all = [None] * len(blocks)
    for key, grp in picture_groups(blocks).items():
        gx, own = group_rows(grp)
        for b, row, o in zip(grp, gx, own):
            X[pos[id(b)]] = row; own_all[pos[id(b)]] = o
    return X, own_all


# ---------------------------------------------------------------------------------------------------------------- words

WORD_NAMES = ['tk_len', 'tk_ascii', 'tk_alpha', 'tk_digit', 'tk_sym', 'tk_cjk', 'tk_hangul', 'tk_under', 'tk_dotmid', 'tk_slash', 'tk_colon_digit', 'tk_paren', 'tk_brackets',
              'tk_camel', 'tk_caps', 'tk_lead_dash', 'tk_lead_special', 'tk_trail_paren', 'tk_hex', 'tk_ver', 'tk_num', 'tk_url', 'tk_ext', 'tk_kw_code', 'tk_kw_weak', 'tk_kw_cmd',
              'tk_capit', 'tk_quote', 'tk_period_end', 'tk_comma_end',
              'tk_pitch', 'tk_pitch_dev', 'tk_h_rel', 'tk_w_rel', 'tk_bg_dist', 'tk_chip', 'tk_prev_chip', 'tk_next_chip', 'tk_pos', 'tk_gap_prev', 'tk_gap_next',
              'nb_prev_len', 'nb_prev_ascii', 'nb_prev_cjk', 'nb_next_len', 'nb_next_ascii', 'nb_next_cjk', 'nb_prev_sym', 'nb_next_sym', 'tk_glued_cjk',
              'b_cjk', 'b_hangul', 'b_ascii_words', 'b_nwords', 'b_sym', 'b_fit', 'b_chips', 'b_lang_ko', 'b_lang_ja', 'b_lang_zh', 'b_lang_en', 'b_vn']


def _shape(s):
    n = max(1, len(s))
    core = s.strip('.,;:!?')
    d = dict.fromkeys(['len', 'ascii', 'alpha', 'digit', 'sym', 'cjk', 'hangul', 'under', 'dotmid', 'slash', 'colon_digit', 'paren', 'brackets', 'camel', 'caps', 'lead_dash',
                       'lead_special', 'trail_paren', 'hex', 'ver', 'num', 'url', 'ext', 'kw_code', 'kw_weak', 'kw_cmd', 'capit', 'quote', 'period_end', 'comma_end'], 0.0)
    d['len'] = float(len(s)); d['ascii'] = float(ascii_only(s))
    d['alpha'] = sum(1 for c in s if c.isascii() and c.isalpha()) / n; d['digit'] = sum(1 for c in s if c.isdigit()) / n
    d['sym'] = sum(1 for c in s if c in SYM) / n
    d['hangul'] = sum(1 for c in s if HANGUL.match(c)) / n
    d['cjk'] = d['hangul'] + sum(1 for c in s if KANA.match(c) or HAN.match(c) or CJKP.match(c)) / n
    d['under'] = float('_' in s); d['dotmid'] = float(bool(re.search(r'\w\.\w', s))); d['slash'] = float('/' in s or '\\' in s)
    d['colon_digit'] = float(bool(re.search(r':\d', s))); d['paren'] = float('(' in s or ')' in s); d['brackets'] = float(any(c in s for c in '[]{}<>'))
    d['camel'] = float(bool(CAMEL.search(s))); d['caps'] = float(len(core) >= 2 and core.isupper() and core.isalpha())
    d['lead_dash'] = float(s.startswith('-')); d['lead_special'] = float(s[:1] in '$@#~./%&*')
    d['trail_paren'] = float(s.endswith(')') or s.endswith('()')); d['hex'] = float(bool(HEX.match(core)) and bool(re.search(r'\d', core)) and bool(re.search('[a-f]', core)))
    d['ver'] = float(bool(VER.match(core))); d['num'] = float(bool(NUM.match(core))); d['url'] = float(bool(URL.search(s)))
    d['ext'] = float('.' in core and core.rsplit('.', 1)[-1] in EXT)
    d['kw_code'] = float(core.strip('()[]{}"\'`') in CODE_KW); d['kw_weak'] = float(core in WEAK_KW); d['kw_cmd'] = float(core in CMD_KW)
    d['capit'] = float(s[:1].isupper() and s[1:].islower()); d['quote'] = float(s[:1] in '"\'`' or s[-1:] in '"\'`')
    d['period_end'] = float(s.endswith(('.', '。'))); d['comma_end'] = float(s.endswith((',', '，', '、')))
    return d


def word_matrix(b, own):
    """-> X (n words, len(WORD_NAMES)) of one block; `own` is the block's own_features dict."""
    words = b['ocr']['w']
    n = len(words)
    X = np.full((n, len(WORD_NAMES)), np.nan, dtype=np.float32)
    if n == 0: return X
    ix = {k: i for i, k in enumerate(WORD_NAMES)}
    medh = float(np.median([w[5] for w in words]))
    shapes = [_shape(w[6]) for w in words]
    ascii_pitch = [w[4] / len(w[6]) for w in words if len(w[6]) >= 3 and ascii_only(w[6])]
    pmed = float(np.median(ascii_pitch)) if ascii_pitch else float('nan')
    wbg = b['wbg']
    bgmed = np.median(wbg, axis=0)
    dist = np.linalg.norm(wbg - bgmed, axis=1) / 441.7
    chip = dist > 0.04
    for i, w in enumerate(words):
        row = X[i]
        for k, v in shapes[i].items(): row[ix['tk_' + k]] = v
        pit = w[4] / max(1, len(w[6]))
        row[ix['tk_pitch']] = pit / max(1.0, w[5]); row[ix['tk_pitch_dev']] = abs(pit - pmed) / pmed if pmed == pmed and pmed > 0 else float('nan')
        row[ix['tk_h_rel']] = w[5] / medh; row[ix['tk_w_rel']] = w[4] / max(1.0, b['ocr']['r'][2])
        row[ix['tk_bg_dist']] = dist[i]; row[ix['tk_chip']] = float(chip[i])
        row[ix['tk_prev_chip']] = float(chip[i - 1]) if i > 0 else 0.0; row[ix['tk_next_chip']] = float(chip[i + 1]) if i + 1 < n else 0.0
        row[ix['tk_pos']] = i / max(1, n - 1)
        if i > 0 and abs((words[i - 1][3] + words[i - 1][5] / 2) - (w[3] + w[5] / 2)) < 0.6 * medh: row[ix['tk_gap_prev']] = (w[2] - (words[i - 1][2] + words[i - 1][4])) / medh
        if i + 1 < n and abs((words[i + 1][3] + words[i + 1][5] / 2) - (w[3] + w[5] / 2)) < 0.6 * medh: row[ix['tk_gap_next']] = (words[i + 1][2] - (w[2] + w[4])) / medh
        for tag, j in (('prev', i - 1), ('next', i + 1)):
            if 0 <= j < n:
                row[ix[f'nb_{tag}_len']] = shapes[j]['len']; row[ix[f'nb_{tag}_ascii']] = shapes[j]['ascii']; row[ix[f'nb_{tag}_cjk']] = shapes[j]['cjk']; row[ix[f'nb_{tag}_sym']] = shapes[j]['sym']
        glued = 0.0
        if shapes[i]['ascii']:
            for j in (i - 1, i + 1):
                if 0 <= j < n and shapes[j]['cjk'] > 0.5 and abs((words[j][3] + words[j][5] / 2) - (w[3] + w[5] / 2)) < 0.6 * medh:
                    gap = (w[2] - (words[j][2] + words[j][4])) if j < i else (words[j][2] - (w[2] + w[4]))
                    if abs(gap) < 0.3 * medh: glued = 1.0
        row[ix['tk_glued_cjk']] = glued
        row[ix['b_cjk']] = own['t_cjk']; row[ix['b_hangul']] = own['t_hangul']; row[ix['b_ascii_words']] = own['w_ascii']; row[ix['b_nwords']] = n; row[ix['b_sym']] = own['t_sym']
        row[ix['b_fit']] = own['m_fit']; row[ix['b_chips']] = float(chip.sum()) / n
        row[ix['b_lang_ko']] = own['lang_ko']; row[ix['b_lang_ja']] = own['lang_ja']; row[ix['b_lang_zh']] = own['lang_zh']; row[ix['b_lang_en']] = own['lang_en']; row[ix['b_vn']] = own['read_vn']
    return X
