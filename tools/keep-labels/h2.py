#!/usr/bin/env python3
"""H2: own developer screens with labels known by construction (round k3a, 2026-10-20).
usage: h2.py <out dir>          writes <name>.html, <name>.units.json for every screen, index.tsv (name, look, src, width, height 0 = the page's own)
                                and MANIFEST.tsv (every source with its sha256 or command, every screen with its look and language)

A screen is one scene (h2_scenes.py: a file, a diff, a log, a terminal session, a README page, a chat, an issue page) drawn in one look (dark or
light terminal, IDE with line numbers, browser page, chat window). The text is taken from this repo at the pinned commit PIN, from the tool-output
fixtures under h2/src/ (captured once, h2/capture.sh), or written for the scene. The generator writes, next to the HTML, the units in reading order:
every unit is a piece of text the screen shows with the class the CONSTRUCTION gives it (addendum A1.1: no shape rule of truth.py is used here):
  keep       a line of code / a command / a log or config line / a hotkey / a path; inline code of a paragraph (`reason|text` or the INLINE table)
  translate  a heading, a paragraph, a list item, a table cell, the UI text of the window: every token of it that is not marked is translate
  either     a name ({n:..}), a time or number ({t:..}), program output in CJK; the labeller makes a token without any letter either
`uncertain` marks what the construction does not settle: the prose-looking comment of a listing (kept by the v1 decision that a code block stays
whole), a path written inside a sentence without code styling. The disagreement sheet takes its rows from there.

Markup of a paragraph: `code` (styled inline code; its reason from INLINE or `reason|text`), [[text]] (code-like text drawn as plain text:
uncertain keep, reason from INLINE), {n:text} (a name: either), {t:text} (a time or number: either), **bold**, *italic*, [link text](url).
Deterministic: no clock, no random, no tool run; the pinned commit and the fixtures decide the text."""
import hashlib, html, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PIN = 'd8e50d8'                                      # the commit the repo excerpts are read from (main when the round started)
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC = os.environ.get('H2_SRC') or os.path.join(HERE, 'h2', 'src')            # H2_SRC: another fixture dir (the FAIL-first of the frozen manifest)
UI = "-apple-system,'Helvetica Neue','Apple SD Gothic Neo','Hiragino Sans','PingFang SC',sans-serif"
CJK = re.compile(r'[\u1100-\u11ff\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uff00-\uffef]')
WIDTH = {'term': 1060, 'ide': 1240, 'md': 1060, 'chat': 980}
INLINE = {}                                          # inline code text -> reason, filled by h2_scenes (the author's decision for each)
MANIFEST_SOURCES = []                                # (id, kind, source, sha256, lang) of what the scenes read


def repo_text(path):
    return subprocess.run(['git', '-C', REPO, 'show', f'{PIN}:{path}'], capture_output=True, text=True, check=True).stdout


def fixture(name):
    with open(os.path.join(SRC, name)) as f:
        return f.read()


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


# ---------------------------------------------------------------------------------------------------------------------- themes
def theme(**kw):
    base = dict(kw=None, st=None, com=None, num=None, typ=None, add=None, rem=None, hunk=None, meta=None, ok=None, bad=None, warn=None)
    base.update(kw)
    return base


MENLO = "Menlo,'Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
SFMONO = "ui-monospace,'SF Mono','Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
MONACO = "Monaco,'Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
COURIER = "'Courier New','Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"

THEMES = {
    'term-dark': theme(page='#1e1e1e', fg='#d4d4d4', dim='#808080', box='#1e1e1e', edge='#333333', bar='#2d2d2d', kw='#c586c0', st='#ce9178',
                       com='#6a9955', num='#b5cea8', typ='#4ec9b0', add='#6a9955', rem='#f14c4c', hunk='#569cd6', meta='#9cdcfe', ok='#6a9955',
                       bad='#f14c4c', warn='#dcdcaa', prompt='#6a9955', desk='#1e1e1e', mono=MENLO),
    'term-light': theme(page='#fafafa', fg='#383a42', dim='#a0a1a7', box='#fafafa', edge='#d4d4d8', bar='#e8e8ea', kw='#a626a4', st='#50a14f',
                        com='#a0a1a7', num='#986801', typ='#c18401', add='#2e7d32', rem='#c62828', hunk='#0184bc', meta='#4078f2', ok='#2e7d32',
                        bad='#c62828', warn='#986801', prompt='#2e7d32', desk='#c9ced6', mono=MONACO),
    'ide-light': theme(page='#ffffff', fg='#1f2328', dim='#8c959f', box='#ffffff', edge='#d8dee4', bar='#ececec', side='#f3f3f3', gut='#f6f6f6',
                       kw='#af00db', st='#a31515', com='#008000', num='#098658', typ='#267f99', add='#116329', rem='#cf222e', hunk='#0550ae',
                       meta='#0451a5', ok='#116329', bad='#cf222e', warn='#9a6700', status='#007acc', statusfg='#ffffff', prompt='#116329', mono=MENLO),
    'ide-dark': theme(page='#1e1e1e', fg='#d4d4d4', dim='#858585', box='#1e1e1e', edge='#333333', bar='#252526', side='#252526', gut='#1e1e1e',
                      kw='#c586c0', st='#ce9178', com='#6a9955', num='#b5cea8', typ='#4ec9b0', add='#6a9955', rem='#f14c4c', hunk='#569cd6',
                      meta='#9cdcfe', ok='#6a9955', bad='#f14c4c', warn='#dcdcaa', status='#007acc', statusfg='#ffffff', prompt='#6a9955', mono=SFMONO),
    'md-light': theme(page='#ffffff', fg='#1f2328', dim='#656d76', box='#f6f8fa', edge='#d0d7de', bar='#f6f8fa', kw='#cf222e', st='#0a3069',
                      com='#6e7781', num='#0550ae', typ='#953800', add='#116329', rem='#82071e', hunk='#0550ae', meta='#8250df', ok='#116329',
                      bad='#cf222e', warn='#9a6700', link='#0969da', prompt='#116329', inline='#eff1f3', mono=MENLO),
    'md-dark': theme(page='#0d1117', fg='#e6edf3', dim='#8d96a0', box='#161b22', edge='#30363d', bar='#161b22', kw='#ff7b72', st='#a5d6ff',
                     com='#8b949e', num='#79c0ff', typ='#ffa657', add='#7ee787', rem='#ffa198', hunk='#79c0ff', meta='#d2a8ff', ok='#7ee787',
                     bad='#ff7b72', warn='#e3b341', link='#4493f8', prompt='#7ee787', inline='#343942', mono=SFMONO),
    'chat-dark': theme(page='#1a1d21', fg='#d1d2d3', dim='#9a9b9e', box='#222529', edge='#36393d', bar='#19171d', kw='#c586c0', st='#ce9178',
                       com='#6a9955', num='#b5cea8', typ='#4ec9b0', add='#6a9955', rem='#f14c4c', hunk='#569cd6', meta='#9cdcfe', ok='#6a9955',
                       bad='#f14c4c', warn='#dcdcaa', link='#1d9bd1', prompt='#6a9955', inline='#2b2e33', mono=COURIER),
    'chat-light': theme(page='#ffffff', fg='#1d1c1d', dim='#616061', box='#f8f8f8', edge='#dddddd', bar='#3f0e40', kw='#a626a4', st='#50a14f',
                        com='#8a8a8a', num='#986801', typ='#c18401', add='#2e7d32', rem='#c62828', hunk='#0184bc', meta='#4078f2', ok='#2e7d32',
                        bad='#c62828', warn='#986801', link='#1264a3', prompt='#2e7d32', inline='#f0f0f0', mono=COURIER),
}
# the untinted code looks (addendum A1.6): a code box with no background of its own, only the page's; a different monospace face
THEMES['md-dark-plain'] = dict(THEMES['md-dark'], box=THEMES['md-dark']['page'], mono=MONACO)
THEMES['chat-light-plain'] = dict(THEMES['chat-light'], box=THEMES['chat-light']['page'], mono=SFMONO)
THEMES['md-light-plain'] = dict(THEMES['md-light'], box=THEMES['md-light']['page'], mono=COURIER)


# ----------------------------------------------------------------------------------------------------------------------- units
class Doc:
    """One screen: the units in reading order, the code regions."""

    def __init__(self, name, lang, look, scene):
        self.name, self.lang, self.look, self.scene = name, lang, look, scene
        self.units, self.nreg, self.regions = [], 0, []

    def region(self):
        self.nreg += 1
        self.regions.append(f'{self.name}-r{self.nreg}')
        return self.regions[-1]

    def unit(self, text, keep=False, reason='', region='', opt=False, inline=(), inline_reasons=None, inline_unc=(), uncertain=False, kind=''):
        u = {'i': len(self.units), 'text': text, 'keep': keep, 'opt': opt, 'reason': reason, 'region': region, 'inline': list(inline),
             'inline_reasons': dict(inline_reasons or {}), 'inline_unc': list(inline_unc), 'uncertain': uncertain, 'kind': kind}
        self.units.append(u)
        return u


RICH = re.compile(r'`(?:(\w+)\|)?([^`]+)`|\[\[([^\]]+)\]\]|\{([nt]):([^}]+)\}|\*\*(.+?)\*\*|\*([^*]+?)\*|\[([^\]]+)\]\(([^)]+)\)')


def inline_reason(sub, given=None):
    r = given or INLINE.get(sub)
    if not r: raise SystemExit(f'h2: inline code without a reason (add it to INLINE): {sub!r}')
    return r


def rich(th, text):
    """Markup -> (html, plain text, inline subs, their reasons, the uncertain subs)."""
    out, plain, inl, reasons, unc = [], [], [], {}, []
    pos = 0
    for m in RICH.finditer(text):
        if m.start() > pos:
            seg = text[pos:m.start()]; out.append(html.escape(seg)); plain.append(seg)
        pos = m.end()
        if m.group(2) is not None:
            sub = m.group(2)
            out.append(f'<code style="font:0.88em {th["mono"]};background:{th["inline"]};border-radius:4px;padding:1px 5px">{html.escape(sub)}</code>')
            plain.append(sub); inl.append(sub); reasons[sub] = inline_reason(sub, m.group(1))
        elif m.group(3) is not None:
            sub = m.group(3); out.append(html.escape(sub)); plain.append(sub); inl.append(sub); reasons[sub] = inline_reason(sub); unc.append(sub)
        elif m.group(4) is not None:
            sub = m.group(5); out.append(html.escape(sub)); plain.append(sub); inl.append(sub); reasons[sub] = 'name' if m.group(4) == 'n' else 'number'
        elif m.group(6) is not None:
            out.append(f'<b>{html.escape(m.group(6))}</b>'); plain.append(m.group(6))
        elif m.group(7) is not None:
            out.append(f'<i>{html.escape(m.group(7))}</i>'); plain.append(m.group(7))
        else:
            out.append(f'<span style="color:{th.get("link") or th["kw"]}">{html.escape(m.group(8))}</span>'); plain.append(m.group(8))
    if pos < len(text):
        seg = text[pos:]; out.append(html.escape(seg)); plain.append(seg)
    return ''.join(out), ''.join(plain), inl, reasons, unc


def para(doc, th, text, kind='prose'):
    """A translated unit (prose with the inline pieces of its markup); returns its html."""
    h, plain, inl, reasons, unc = rich(th, text)
    doc.unit(plain, inline=inl, inline_reasons=reasons, inline_unc=unc, kind=kind)
    return h


def ui_text(doc, text, kind='ui'):
    """A short piece of the window's own text (a sidebar header, a status field): translated."""
    doc.unit(text, kind=kind)
    return html.escape(text)


# ----------------------------------------------------------------------------------------------------------------------- lines
class Line:
    def __init__(self, text, reason='code', unc=False, opt=False):
        self.text, self.reason, self.unc, self.opt = text, reason, unc, opt


MARK = re.compile(r'\s*⟦(u|o|r:\w+)⟧$')
COMMENT = re.compile(r'(?:^|\s)(?://+|#+)\s+(.*)$')


def lines_of(block, lang='sh', reason='code'):
    """Lines of a multi-line text. A trailing ⟦u⟧ marks the line uncertain, ⟦o⟧ either, ⟦r:xxx⟧ names its reason. A comment of a
    source language (swift, sh, yaml, py) with three words or any CJK is uncertain: it reads as prose."""
    out = []
    for raw in block.strip('\n').split('\n'):
        m = MARK.search(raw)
        flag = m.group(1) if m else ''
        text = raw[:m.start()] if m else raw
        unc = flag == 'u'; opt = flag == 'o'; r = flag[2:] if flag.startswith('r:') else reason
        if lang in ('swift', 'sh', 'yaml', 'py') and not unc and not opt:
            c = COMMENT.search(text)
            if c and not text.startswith('#!') and (len(c.group(1).split()) >= 3 or CJK.search(c.group(1))): unc = True
        if lang == 'json' and CJK.search(text): unc = True
        out.append(Line(text.rstrip(), r, unc, opt))
    return out


class Listing:
    """What a code box shows: the lines, their language for the colours, a file path (the IDE tab, the `cat` of a terminal)."""

    def __init__(self, lines, lang='plain', path=None, cmd=None):
        self.lines, self.lang, self.path, self.cmd = lines, lang, path, cmd


def verify(lines, path, lang='swift'):
    """Every code line of an excerpt (its comment cut off) is a line of the repo file at PIN: the excerpt is taken from the repo, not written.
    Records the file in the manifest. Returns the lines."""
    pat = {'swift': r'\s+//\s.*$', 'sh': r'\s+#\s.*$', 'yaml': r'\s+#\s.*$', 'py': r'\s+#\s.*$'}[lang]
    text = repo_text(path)
    src = {re.sub(pat, '', l).strip() for l in text.split('\n')}
    for ln in lines:
        code = ln.text.strip()
        if not code or re.match(r'(//|#)', code): continue
        cut = re.sub(pat, '', code).strip()
        if cut and cut not in src:
            raise SystemExit(f'h2: line not in {path}@{PIN}: {code!r}')
    note_source(path, 'repo-file', f'git show {PIN}:{path}', text)
    return lines


def note_source(sid, kind, source, text, lang=''):
    if all(r[0] != sid for r in MANIFEST_SOURCES): MANIFEST_SOURCES.append((sid, kind, source, sha(text), lang))


# ------------------------------------------------------------------------------------------------------------------ highlighting
KW = {
    'swift': 'public private fileprivate internal func let var struct enum class final case if else guard return for in while switch default init self '
             'static import async await throws try catch do some any extension protocol typealias where mutating @escaping @Sendable nil true false',
    'sh': 'if then else elif fi for in do done case esac function local return exit set export while read echo',
    'py': 'def class return if else elif for in while import from as try except finally with None True False global lambda',
}
TOK = {
    'swift': r'(?P<com>//.*$)|(?P<st>"(?:\\.|[^"\\])*")|(?P<num>\b\d[\d_.]*\b)|(?P<id>[@A-Za-z_][A-Za-z_0-9]*)',
    'py': r'(?P<com>#.*$)|(?P<st>f?\'(?:\\.|[^\'\\])*\'|f?"(?:\\.|[^"\\])*")|(?P<num>\b\d[\d_.]*\b)|(?P<id>[A-Za-z_][A-Za-z_0-9]*)',
    'sh': r'(?P<com>(?<![\w$])#(?!!).*$)|(?P<st>"(?:\\.|[^"\\])*"|\'[^\']*\')|(?P<num>\b\d+\b)|(?P<var>\$[{(]?[A-Za-z_@#?0-9]+)|(?P<id>[A-Za-z_][A-Za-z_0-9-]*)',
    'yaml': r'(?P<com>(?:^|\s)#.*$)|(?P<st>"(?:\\.|[^"\\])*")|(?P<num>\b\d[\d.]*\b)|(?P<key>^\s*(?:- )?[A-Za-z_][\w.]*(?=:))|(?P<id>[A-Za-z_][\w]*)',
    'json': r'(?P<key>"(?:\\.|[^"\\])*"(?=\s*:))|(?P<st>"(?:\\.|[^"\\])*")|(?P<num>-?\b\d[\d.]*\b)|(?P<id>\b(?:true|false|null)\b)',
}


def span(color, text, bold=False):
    return f'<span style="color:{color}{";font-weight:600" if bold else ""}">{html.escape(text)}</span>'


def highlight(text, lang, th):
    """HTML of one code line with the colours of the theme (the text itself is unchanged)."""
    if not text: return '&nbsp;'
    if lang == 'diff':
        c = text[:1]
        if text.startswith(('diff ', 'index ', '--- ', '+++ ')): return span(th['dim'], text, bold=text.startswith('diff '))
        if text.startswith('@@'): return span(th['hunk'], text)
        if c == '+': return span(th['add'], text)
        if c == '-': return span(th['rem'], text)
        return html.escape(text)
    if lang == 'term':
        m = re.match(r'^(\$ )(.*)$', text)
        if m: return span(th['prompt'], m.group(1), bold=True) + html.escape(m.group(2))
        return html.escape(text)
    if lang == 'log':
        if re.search(r'\b(error|failed|✘|FAIL|FAILED)\b', text): return span(th['bad'], text)
        if re.search(r'\bwarning\b', text): return span(th['warn'], text)
        if re.match(r'^(✔|\*\* BUILD SUCCEEDED|ok )', text): return span(th['ok'], text)
        if text.startswith(('↳', '◇')): return span(th['dim'], text)
        return html.escape(text)
    if lang not in TOK: return html.escape(text)
    kws = set(KW.get(lang, '').split())
    out, pos = [], 0
    for m in re.finditer(TOK[lang], text):
        if m.start() > pos: out.append(html.escape(text[pos:m.start()]))
        pos = m.end(); g = m.lastgroup; s = m.group(0)
        if g == 'com': out.append(span(th['com'], s))
        elif g == 'st': out.append(span(th['st'], s))
        elif g == 'num': out.append(span(th['num'], s))
        elif g in ('var', 'key'): out.append(span(th['meta'], s))
        elif g == 'id':
            if s in kws: out.append(span(th['kw'], s))
            elif lang in ('swift', 'py') and s[:1].isupper(): out.append(span(th['typ'], s))
            elif lang == 'json': out.append(span(th['kw'], s))
            else: out.append(html.escape(s))
        else: out.append(html.escape(s))
    out.append(html.escape(text[pos:]))
    return ''.join(out)


def add_line_unit(doc, ln, region):
    if not ln.text.strip(): return
    if ln.opt: doc.unit(ln.text.strip(), opt=True, reason='cjk-output', region=region, kind='line')
    else: doc.unit(ln.text.strip(), keep=True, reason=ln.reason, region=region, uncertain=ln.unc, kind='line')


def emit_lines(doc, th, lst, region, lh, extra_cmd=None):
    """The rows of a code box as html, one div per line (a long line wraps, as a terminal's does); one unit per non-empty line."""
    rows = []
    allv = ([Line('$ ' + extra_cmd, 'cmd')] if extra_cmd else []) + lst.lines
    for ln in allv:
        add_line_unit(doc, ln, region)
        lang = 'term' if ln is allv[0] and extra_cmd else lst.lang
        rows.append(f'<div style="white-space:pre-wrap;overflow-wrap:anywhere;min-height:{lh}px;line-height:{lh}px">{highlight(ln.text, lang, th)}</div>')
    return ''.join(rows)


# --------------------------------------------------------------------------------------------------------------------------- looks
def page(th, w, body, extra_css=''):
    return (f'<!doctype html><meta charset=utf-8><style>*{{box-sizing:border-box}}html{{background:{th["page"]}}}'
            f'body{{margin:0;width:{w}px;background:{th["page"]};color:{th["fg"]};font:15px/1.55 {UI}}}{extra_css}</style><body>{body}</body>')


def code_box(doc, th, lst, fs=12.5, lh=19, caption=None, pad=14, extra_cmd=None):
    """A framed code box (md, chat): optional caption bar with the file path."""
    region = doc.region()
    cap = ''
    if caption:
        doc.unit(caption, keep=True, reason='path', kind='caption')
        cap = (f'<div style="font:{fs}px {th["mono"]};padding:6px {pad}px;border-bottom:1px solid {th["edge"]};color:{th["dim"]}">{html.escape(caption)}</div>')
    rows = emit_lines(doc, th, lst, region, lh, extra_cmd)
    return (f'<div style="background:{th["box"]};border:1px solid {th["edge"]};border-radius:8px;margin:12px 0;overflow:hidden">{cap}'
            f'<div style="font:{fs}px {th["mono"]};padding:{pad - 2}px {pad}px">{rows}</div></div>')


def look_term(doc, sc, th, boxed):
    """A terminal: the listing's lines (a file is shown with `cat`), full bleed or a window on a desktop."""
    lst = sc['listing']
    region = doc.region()
    rows = emit_lines(doc, th, lst, region, 19, extra_cmd=lst.cmd)
    dots = ''.join(f'<i style="display:inline-block;width:11px;height:11px;border-radius:6px;background:{c};margin-right:7px"></i>' for c in ('#ff5f57', '#febc2e', '#28c840'))
    bar = f'<div style="background:{th["bar"]};height:30px;padding:9px 14px">{dots}</div>'
    body = f'<div style="font:13px {th["mono"]};padding:12px 16px 18px">{rows}</div>'
    if boxed:
        win = f'<div style="margin:26px;border-radius:10px;overflow:hidden;background:{th["box"]};border:1px solid {th["edge"]}">{bar}{body}</div>'
        return page(dict(th, page=th['desk']), WIDTH['term'], win)
    return page(th, WIDTH['term'], bar + body)


def look_ide(doc, sc, th, _boxed):
    """An editor: sidebar with files, tab bar, breadcrumb, gutter with line numbers, code, status bar."""
    lst, lang = sc['listing'], sc['lang']
    path = lst.path
    base = path.rsplit('/', 1)[-1]
    head = {'en': 'EXPLORER', 'ko': '탐색기', 'ja': 'エクスプローラー'}[lang]
    status = {'en': 'Ln %d, Col 9', 'ko': '줄 %d, 열 9', 'ja': '%d行、9列'}[lang] % (len(lst.lines) // 2 + 3)
    side = f'<div style="width:210px;background:{th["side"]};padding:10px 0;border-right:1px solid {th["edge"]};font-size:13px">'
    side += f'<div style="padding:2px 16px 8px;color:{th["dim"]};font-size:11px;letter-spacing:.5px">{ui_text(doc, head, "sidebar")}</div>'
    for f in sc['siblings'] + [base]:
        doc.unit(f, keep=True, reason='path', kind='sidebar')
        sel = f'background:{th["edge"]};' if f == base else ''
        side += f'<div style="{sel}padding:3px 16px">{html.escape(f)}</div>'
    side += '</div>'
    doc.unit(base, keep=True, reason='path', kind='tab')
    tabs = (f'<div style="background:{th["bar"]};display:flex;font-size:13px;border-bottom:1px solid {th["edge"]}">'
            f'<div style="padding:8px 18px;background:{th["page"]};border-right:1px solid {th["edge"]}">{html.escape(base)}</div></div>')
    crumb_txt = ' › '.join(path.split('/')[-4:])
    doc.unit(crumb_txt, keep=True, reason='path', uncertain=True, kind='breadcrumb')
    crumb = f'<div style="padding:5px 16px;font-size:12px;color:{th["dim"]}">{html.escape(crumb_txt)}</div>'
    region = doc.region()
    n = len(lst.lines)
    doc.unit(' '.join(str(k + 1) for k in range(n)), keep=True, reason='lineno', kind='gutter')          # the gutter the look draws
    gut, rows = [], []
    for k, ln in enumerate(lst.lines):
        add_line_unit(doc, ln, region)
        gut.append(f'<div style="height:18px;line-height:18px">{k + 1}</div>')
        rows.append(f'<div style="white-space:pre;height:18px;line-height:18px">{highlight(ln.text, lst.lang, th)}</div>')
    editor = (f'<div style="display:flex;font:12px {th["mono"]};padding:6px 0 14px">'
              f'<div style="width:52px;text-align:right;padding-right:14px;color:{th["dim"]};background:{th["gut"]}">{"".join(gut)}</div>'
              f'<div style="padding-left:6px">{"".join(rows)}</div></div>')
    mode = lst.lang.capitalize() if lst.lang != 'sh' else 'Shell'
    doc.unit(status, kind='status')
    doc.unit('UTF-8', opt=True, reason='name', kind='status')
    doc.unit(mode, opt=True, reason='name', kind='status')
    bar = (f'<div style="background:{th["status"]};color:{th["statusfg"]};font-size:12px;padding:4px 14px;display:flex;gap:22px">'
           f'<span>{html.escape(status)}</span><span>UTF-8</span><span>{html.escape(mode)}</span></div>')
    main = f'<div style="display:flex;min-height:300px">{side}<div style="flex:1;min-width:0">{tabs}{crumb}{editor}</div></div>'
    return page(th, WIDTH['ide'], main + bar)


def block_md(doc, th, b, ctx):
    """One block of a browser page / chat message as html."""
    kind = b[0]
    if kind in ('h1', 'h2', 'h3'):
        size = {'h1': 28, 'h2': 21, 'h3': 17}[kind]
        rule = f'border-bottom:1px solid {th["edge"]};padding-bottom:8px;' if kind != 'h3' else ''
        return f'<div style="font-size:{size}px;font-weight:700;margin:{18 if kind != "h1" else 4}px 0 10px;{rule}">{para(doc, th, b[1], "heading")}</div>'
    if kind == 'p':
        return f'<p style="margin:9px 0">{para(doc, th, b[1])}</p>'
    if kind == 'ul':
        items = ''.join(f'<li style="margin:4px 0">{para(doc, th, t, "item")}</li>' for t in b[1])
        return f'<ul style="margin:8px 0;padding-left:26px">{items}</ul>'
    if kind == 'table':
        head, rows = b[1], b[2]

        def cell(t, tag):
            m = re.match(r'^!(\w+)\|(.*)$', t)                 # !reason|text: a cell that is itself kept (a hotkey)
            if m:
                doc.unit(m.group(2), keep=True, reason=m.group(1), kind='cell')
                inner = html.escape(m.group(2))
            else: inner = para(doc, th, t, "cell") if t.strip() else ""
            return f'<{tag} style="border:1px solid {th["edge"]};padding:6px 12px;text-align:left;vertical-align:top">{inner}</{tag}>'
        hd = f'<tr>{"".join(cell(c, "th") for c in head)}</tr>' if any(c.strip() for c in head) else ''
        rs = ''.join(f'<tr>{"".join(cell(c, "td") for c in r)}</tr>' for r in rows)
        return f'<table style="border-collapse:collapse;margin:12px 0;font-size:14px;width:100%">{hd}{rs}</table>'
    if kind == 'code':
        return code_box(doc, th, b[1], caption=b[2], extra_cmd=b[3])
    if kind == 'meta':
        return f'<div style="color:{th["dim"]};font-size:13px;margin:6px 0 14px">{para(doc, th, b[1], "meta")}</div>'
    raise SystemExit(f'h2: block {kind}')


def look_md(doc, sc, th, _boxed):
    """A browser page (GitHub-like): breadcrumb, blocks."""
    h, plain, inl, reasons, unc = rich(th, '{n:midagedev} / {n:mwoyeo}')
    doc.unit(plain, inline=inl, inline_reasons=reasons, kind='breadcrumb')
    top = (f'<div style="background:{th["bar"]};border-bottom:1px solid {th["edge"]};padding:14px 40px;font-size:14px;color:{th["dim"]}">{h}</div>')
    body = ''.join(block_md(doc, th, b, sc) for b in sc['md'])
    return page(th, WIDTH['md'], top + f'<div style="padding:22px 40px 40px">{body}</div>')


def look_chat(doc, sc, th, _boxed):
    """A chat window: channel bar, messages (name, time, text, code)."""
    chan = sc['channel']
    doc.unit('# ' + chan, opt=True, reason='name', kind='channel')
    top = (f'<div style="background:{th["bar"]};color:#fff;padding:12px 22px;font-weight:700;font-size:15px;border-bottom:1px solid {th["edge"]}">'
           f'{html.escape("# " + chan)}</div>')
    msgs = []
    for who, when, blocks in sc['chat']:
        doc.unit(who, opt=True, reason='name', kind='name')
        doc.unit(when, opt=True, reason='number', kind='time')
        inner = ''.join(block_md(doc, th, b, sc) for b in blocks)
        msgs.append(f'<div style="display:flex;gap:12px;padding:8px 22px"><div style="width:38px;height:38px;border-radius:6px;background:{"#e8912d" if len(msgs) % 2 else "#2eb67d"};flex:none"></div>'
                    f'<div style="min-width:0;flex:1"><div><b>{html.escape(who)}</b> <span style="color:{th["dim"]};font-size:12px;margin-left:6px">{html.escape(when)}</span></div>'
                    f'<div style="font-size:15px">{inner}</div></div></div>')
    return page(th, WIDTH['chat'], top + f'<div style="padding:10px 0 24px">{"".join(msgs)}</div>')


LOOKS = {'term': look_term, 'ide': look_ide, 'md': look_md, 'chat': look_chat}


def build(scene, look_name):
    """-> (doc, html). look_name: 'term-dark', 'term-light' (a window on a desktop), 'ide-light', 'ide-dark', 'md-*', 'chat-*' (-plain: untinted code)."""
    kind = look_name.split('-')[0]
    th = THEMES[look_name]
    doc = Doc(f'{scene["id"]}.{look_name}', scene['lang'], look_name, scene['id'])
    return doc, LOOKS[kind](doc, scene, th, look_name == 'term-light')


def main():
    import h2_scenes
    SCENES = h2_scenes.SCENES
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rows = []
    for sc in SCENES:
        for look in sc['looks']:
            doc, htm = build(sc, look)
            if os.environ.get('H2_MUTATE'): htm += '<!-- mutated -->'                 # the FAIL-first of the determinism check
            with open(f'{out}/{doc.name}.html', 'w') as f: f.write(htm)
            with open(f'{out}/{doc.name}.units.json', 'w') as f:
                json.dump({'name': doc.name, 'lang': doc.lang, 'look': look, 'scene': sc['id'], 'regions': doc.regions, 'units': doc.units},
                          f, ensure_ascii=False, indent=0, sort_keys=True)
            rows.append((doc.name, look.split('-')[0], doc.lang, WIDTH[look.split('-')[0]], 0, sc['id'], look, THEMES[look]['mono'].split(',')[0].strip("'")))
    with open(f'{out}/index.tsv', 'w') as f:
        f.write('name\tlook\tsrc\twidth\theight\n')
        for r in rows: f.write('\t'.join(map(str, r[:5])) + '\n')
    with open(f'{out}/MANIFEST.tsv', 'w') as f:
        f.write('# sources of the text (path or command, sha256 of the text read); authored = written for the scene, in h2_scenes.py\n')
        f.write('id\tkind\tsource\tsha256\tlang\n')
        for r in sorted(MANIFEST_SOURCES): f.write('\t'.join(r) + '\n')
        for sc in SCENES:
            f.write(f'{sc["id"]}\tauthored\th2_scenes.py scene {sc["id"]}\t-\t{sc["lang"]}\n')
        f.write('# screens: name, scene, look, language given to ocrdump, monospace face\n')
        for r in rows: f.write(f'{r[0]}\tscreen\t{r[5]} {r[6]}\t{r[7]}\t{r[2]}\n')
    print(f'h2: {len(rows)} screens of {len(SCENES)} scenes in {out}')


if __name__ == '__main__':
    import h2                                         # run as the module the scenes import, so they share its tables
    h2.main()
