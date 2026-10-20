"""The looks of H3 (h3_scenes.py draws with them): themes and layouts added to h2.py's tables, so h2.py's own looks and output do not change.
New layouts: pane (a narrow editor docked in a side panel, long lines wrap), docs (a documentation site with a left nav, a table of contents, a footer),
review (a code review page: two line-number gutters, a sign column, a commit panel, a comment thread), card (notification-sized cards).
New themes of the families H2 has: term-solarized, term-green; ide-solar; md-sepia, md-night; chat-dark-plain (untinted inline code), chat-mint.
Imported once by h3_scenes.py; every label is still the construction's (h2.py's units), nothing here knows a shape rule."""
import html, re
import h2
from h2 import THEMES, LOOKS, WIDTH, UI, add_line_unit, block_md, emit_lines, highlight, para, rich, theme, ui_text

PT = "'PT Mono','Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
ANDALE = "'Andale Mono','Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
COURIER = "Courier,'Apple SD Gothic Neo','Hiragino Sans','PingFang SC',monospace"
MENLO = h2.MENLO
MONACO = h2.MONACO
SFMONO = h2.SFMONO

# ------------------------------------------------------------------------------------------------------------------------- themes
THEMES['term-solarized'] = theme(page='#002b36', fg='#93a1a1', dim='#657b83', box='#002b36', edge='#0a4452', bar='#073642', kw='#859900', st='#2aa198',
                                 com='#586e75', num='#d33682', typ='#b58900', add='#859900', rem='#dc322f', hunk='#268bd2', meta='#268bd2', ok='#859900',
                                 bad='#dc322f', warn='#b58900', prompt='#859900', desk='#002b36', mono=PT)
THEMES['term-green'] = theme(page='#050805', fg='#3fe65c', dim='#238a37', box='#050805', edge='#14301a', bar='#101a12', kw='#8dff9f', st='#b8ffc4',
                             com='#238a37', num='#8dff9f', typ='#8dff9f', add='#8dff9f', rem='#ff7b7b', hunk='#6ee7ff', meta='#6ee7ff', ok='#8dff9f',
                             bad='#ff7b7b', warn='#f2e66b', prompt='#8dff9f', desk='#20242a', mono=ANDALE, boxed=True)
THEMES['ide-solar'] = theme(page='#fdf6e3', fg='#586e75', dim='#93a1a1', box='#fdf6e3', edge='#e4dcc4', bar='#eee8d5', side='#eee8d5', gut='#f5eed9',
                            kw='#859900', st='#2aa198', com='#93a1a1', num='#d33682', typ='#b58900', add='#6f8200', rem='#dc322f', hunk='#268bd2',
                            meta='#268bd2', ok='#6f8200', bad='#dc322f', warn='#b58900', status='#268bd2', statusfg='#fdf6e3', prompt='#6f8200', mono=ANDALE)
THEMES['md-sepia'] = theme(page='#f4ecd8', fg='#433422', dim='#7a6a53', box='#ebe0c5', edge='#d8c9a8', bar='#ebe0c5', kw='#9c4221', st='#276749',
                           com='#8b7d63', num='#8a5a00', typ='#6b4a00', add='#276749', rem='#9b2c2c', hunk='#2b6cb0', meta='#6b46c1', ok='#276749',
                           bad='#9b2c2c', warn='#8a5a00', link='#2b6cb0', prompt='#276749', inline='#e5d8b8', mono=COURIER)
THEMES['md-night'] = theme(page='#0b1220', fg='#d6deeb', dim='#7f8ea3', box='#111a2e', edge='#22304d', bar='#111a2e', kw='#c792ea', st='#ecc48d',
                           com='#637777', num='#f78c6c', typ='#ffcb8b', add='#addb67', rem='#ef5350', hunk='#82aaff', meta='#7fdbca', ok='#addb67',
                           bad='#ef5350', warn='#ffcb8b', link='#82aaff', prompt='#addb67', inline='#1d2b4a', mono=PT)
THEMES['chat-dark-plain'] = theme(page='#1b1f27', fg='#d7dae0', dim='#8a919e', box='#1b1f27', edge='#313846', bar='#14171d', kw='#c586c0', st='#ce9178',
                                  com='#6a9955', num='#b5cea8', typ='#4ec9b0', add='#6a9955', rem='#f14c4c', hunk='#569cd6', meta='#9cdcfe', ok='#6a9955',
                                  bad='#f14c4c', warn='#dcdcaa', link='#4aa3ff', prompt='#6a9955', inline='#1b1f27', mono=COURIER)
THEMES['chat-mint'] = theme(page='#f4fbf7', fg='#1d2b24', dim='#5c6f66', box='#e3f4ea', edge='#c4e3d2', bar='#0f6b4a', kw='#a626a4', st='#2f7d4f',
                            com='#6f8a7b', num='#986801', typ='#8a6200', add='#2e7d32', rem='#c62828', hunk='#0184bc', meta='#4078f2', ok='#2e7d32',
                            bad='#c62828', warn='#986801', link='#0b7a5a', prompt='#2e7d32', inline='#d3eede', mono=ANDALE)
THEMES['pane-dark'] = theme(page='#252526', fg='#cccccc', dim='#858585', box='#1e1e1e', edge='#3c3c3c', bar='#333333', gut='#1e1e1e', kw='#c586c0',
                            st='#ce9178', com='#6a9955', num='#b5cea8', typ='#4ec9b0', add='#6a9955', rem='#f14c4c', hunk='#569cd6', meta='#9cdcfe',
                            ok='#6a9955', bad='#f14c4c', warn='#dcdcaa', prompt='#6a9955', mono=MENLO)
THEMES['pane-light'] = theme(page='#f3f3f3', fg='#333333', dim='#8a8a8a', box='#ffffff', edge='#d4d4d4', bar='#e8e8e8', gut='#f7f7f7', kw='#0000ff',
                             st='#a31515', com='#008000', num='#098658', typ='#267f99', add='#116329', rem='#cf222e', hunk='#0550ae', meta='#0451a5',
                             ok='#116329', bad='#cf222e', warn='#9a6700', prompt='#116329', mono=MONACO)
THEMES['docs-light'] = theme(page='#ffffff', fg='#1c2430', dim='#5b6675', box='#f3f5f8', edge='#dde2ea', bar='#ffffff', side='#f7f8fa', kw='#b3261e',
                             st='#0a6640', com='#6b7685', num='#a15c00', typ='#7b3fbf', add='#116329', rem='#b3261e', hunk='#0b6bcb', meta='#7b3fbf',
                             ok='#116329', bad='#b3261e', warn='#9a6700', link='#0b6bcb', prompt='#116329', inline='#eef1f5', mono=SFMONO)
THEMES['docs-dark'] = theme(page='#121417', fg='#dfe3e8', dim='#8b95a3', box='#1b1f24', edge='#2c333b', bar='#16191d', side='#16191d', kw='#ff8a80',
                            st='#81d4a6', com='#7f8a98', num='#ffb74d', typ='#b39ddb', add='#81d4a6', rem='#ff8a80', hunk='#64b5f6', meta='#b39ddb',
                            ok='#81d4a6', bad='#ff8a80', warn='#ffb74d', link='#64b5f6', prompt='#81d4a6', inline='#262c33', mono=MONACO)
THEMES['review-light'] = theme(page='#ffffff', fg='#1f2328', dim='#656d76', box='#f6f8fa', edge='#d0d7de', bar='#f6f8fa', gut='#f6f8fa', kw='#cf222e',
                               st='#0a3069', com='#6e7781', num='#0550ae', typ='#953800', add='#116329', rem='#82071e', hunk='#0550ae', meta='#8250df',
                               ok='#116329', bad='#cf222e', warn='#9a6700', link='#0969da', prompt='#116329', inline='#eff1f3', mono=ANDALE,
                               addbg='#e6ffec', rembg='#ffebe9', hunkbg='#ddf4ff')
THEMES['review-dark'] = theme(page='#0d1117', fg='#e6edf3', dim='#8d96a0', box='#161b22', edge='#30363d', bar='#161b22', gut='#161b22', kw='#ff7b72',
                              st='#a5d6ff', com='#8b949e', num='#79c0ff', typ='#ffa657', add='#7ee787', rem='#ffa198', hunk='#79c0ff', meta='#d2a8ff',
                              ok='#7ee787', bad='#ff7b72', warn='#e3b341', link='#4493f8', prompt='#7ee787', inline='#343942', mono=PT,
                              addbg='#12261e', rembg='#2d1517', hunkbg='#10243e')
THEMES['card-light'] = theme(page='#dfe3ea', fg='#1d1d1f', dim='#6e6e73', box='#f0f1f4', edge='#d2d5db', bar='#fbfbfc', kw='#a626a4', st='#50a14f',
                             com='#8a8a8a', num='#986801', typ='#c18401', add='#2e7d32', rem='#c62828', hunk='#0184bc', meta='#4078f2', ok='#2e7d32',
                             bad='#c62828', warn='#986801', link='#0a62c9', prompt='#2e7d32', inline='#e8eaee', mono=PT, cardbg='#fbfbfc')
THEMES['card-dark'] = theme(page='#101012', fg='#f5f5f7', dim='#a1a1a6', box='#1c1c1e', edge='#3a3a3c', bar='#2c2c2e', kw='#ff7ab2', st='#ff8170',
                            com='#7f8c98', num='#d9c97c', typ='#78c2b3', add='#7ee787', rem='#ff8170', hunk='#6bdfff', meta='#6bdfff', ok='#7ee787',
                            bad='#ff8170', warn='#d9c97c', link='#64a8ff', prompt='#7ee787', inline='#3a3a3c', mono=MENLO, cardbg='#2c2c2e')

# xml (a plist) and key = value (xcconfig) files are not in h2.py's token table
h2.TOK['xml'] = r'(?P<com><!--.*?-->)|(?P<key></?[A-Za-z][\w.-]*)|(?P<st>"[^"]*")'
h2.TOK['conf'] = r'(?P<com>//.*$)|(?P<key>^[A-Z][A-Z0-9_]*(?=\s*=))|(?P<var>\$\([^)]*\))|(?P<id>[A-Za-z_][\w]*)'
h2.KW['conf'] = 'YES NO'

WIDTH.update({'pane': 560, 'docs': 1180, 'review': 1180, 'card': 440})


# ------------------------------------------------------------------------------------------------------------------------- pane
def look_pane(doc, sc, th, _boxed):
    """A narrow editor docked beside the work (a side panel): a title bar, one file tab, a gutter, code that wraps, a status line."""
    lst, lang = sc['listing'], sc['lang']
    base = lst.path.rsplit('/', 1)[-1]
    n = len(lst.lines)
    title = ui_text(doc, sc['pane_title'], 'pane-title')
    doc.unit(base, keep=True, reason='path', kind='tab')
    tab = (f'<div style="background:{th["bar"]};padding:7px 14px;font:12px {UI};border-bottom:1px solid {th["edge"]};color:{th["dim"]}">'
           f'<span style="color:{th["fg"]}">{html.escape(base)}</span></div>')
    region = doc.region()
    doc.unit(' '.join(str(k + 1) for k in range(n)), keep=True, reason='lineno', kind='gutter')
    rows = []
    for k, ln in enumerate(lst.lines):
        add_line_unit(doc, ln, region)
        rows.append(f'<div style="display:flex"><div style="width:34px;flex:none;text-align:right;padding-right:10px;color:{th["dim"]}">{k + 1}</div>'
                    f'<div style="flex:1;min-width:0;white-space:pre-wrap;overflow-wrap:anywhere">{highlight(ln.text, lst.lang, th)}</div></div>')
    status = sc['pane_status'] % n
    doc.unit(status, kind='status')
    foot = f'<div style="padding:6px 14px;font:12px {UI};color:{th["dim"]};border-top:1px solid {th["edge"]}">{html.escape(status)}</div>'
    head = (f'<div style="padding:10px 14px;font:600 13px {UI};letter-spacing:.3px;color:{th["dim"]}">{title}</div>')
    code = (f'<div style="background:{th["box"]};font:12px {th["mono"]};line-height:18px;padding:10px 6px 12px 6px">{"".join(rows)}</div>')
    return h2.page(th, WIDTH['pane'], head + tab + code + foot)


# ------------------------------------------------------------------------------------------------------------------------- docs
def look_docs(doc, sc, th, _boxed):
    """A documentation site: top bar with a search field, a left nav (groups and pages), the page, a footer, a table of contents on the right.
    The units follow the page's reading order: site name, search, nav, page, footer, contents."""
    d = sc['docs']
    doc.unit('Mwoyeo', opt=True, reason='name', kind='site')
    search = ui_text(doc, d['search'], 'search')
    top = (f'<div style="display:flex;align-items:center;gap:24px;padding:12px 28px;border-bottom:1px solid {th["edge"]};background:{th["bar"]}">'
           f'<b style="font-size:17px">Mwoyeo</b>'
           f'<span style="border:1px solid {th["edge"]};border-radius:6px;padding:5px 14px;font-size:13px;color:{th["dim"]};width:260px">{search}</span></div>')
    nav = ''
    for group, items in d['nav']:
        nav += f'<div style="padding:12px 20px 4px;font-size:11px;letter-spacing:.6px;color:{th["dim"]}">{ui_text(doc, group, "nav-group")}</div>'
        for it in items:
            cur = it == d['current']
            doc.unit(it, kind='nav')
            nav += (f'<div style="padding:5px 20px;font-size:14px;{"font-weight:700;border-left:3px solid " + th["link"] + ";padding-left:17px" if cur else ""}">'
                    f'{html.escape(it)}</div>')
    side = f'<div style="width:236px;flex:none;background:{th["side"]};border-right:1px solid {th["edge"]};padding-bottom:20px">{nav}</div>'
    body = ''.join(block_md(doc, th, b, sc) for b in sc['md'])
    foot = (f'<div style="margin-top:28px;padding-top:12px;border-top:1px solid {th["edge"]};font-size:13px;color:{th["dim"]}">'
            f'{ui_text(doc, d["edit"], "footer")} · {html.escape(d["updated"])}</div>')
    doc.unit(d['updated'], opt=True, reason='number', kind='footer')
    toc = f'<div style="padding:4px 0 6px;font-size:11px;letter-spacing:.6px;color:{th["dim"]}">{ui_text(doc, d["toc_title"], "toc-title")}</div>'
    for b in sc['md']:
        if b[0] in ('h2', 'h3'):
            _h, plain, inl, _r, _u = rich(th, b[1])
            if inl: raise SystemExit(f'h3: a heading with inline pieces cannot be repeated in the contents: {b[1]!r}')
            toc += f'<div style="padding:3px 0;font-size:13px;color:{th["dim"]}">{ui_text(doc, plain, "toc")}</div>'
    main = (f'<div style="flex:1;min-width:0;padding:22px 36px 40px">{body}{foot}</div>'
            f'<div style="width:190px;flex:none;padding:26px 16px 0 0">{toc}</div>')
    return h2.page(th, WIDTH['docs'], top + f'<div style="display:flex;min-height:420px">{side}{main}</div>')


# ------------------------------------------------------------------------------------------------------------------------- review
HUNK = re.compile(r'^@@ -(\d+)(?:,\d+)? \+(\d+)')


def look_review(doc, sc, th, _boxed):
    """A code review page: the pull request's title, the file's diff with an old and a new line-number gutter and a sign column, the commits of the
    pull request (hash and summary), and a comment thread. The diff lines are the units; a hunk header is a diffmark line."""
    rv = sc['review']
    head = (f'<div style="padding:18px 32px 10px"><div style="font-size:24px;font-weight:700">{para(doc, th, rv["title"], "heading")}</div>'
            f'<div style="color:{th["dim"]};font-size:13px;margin-top:6px">{para(doc, th, rv["meta"], "meta")}</div></div>')
    path = rv['file']
    doc.unit(path, keep=True, reason='path', kind='caption')
    fhead = (f'<div style="margin:0 32px;border:1px solid {th["edge"]};border-radius:6px 6px 0 0;background:{th["bar"]};padding:8px 14px;'
             f'font:12.5px {th["mono"]}">{html.escape(path)}</div>')
    region = doc.region()
    gutter = doc.unit('', keep=True, reason='lineno', kind='gutter')                  # the two gutters of the look; the text is filled in below
    old = new = 0
    rows, nums = [], []
    for ln in rv['diff']:
        add_line_unit(doc, ln, region)
        m = HUNK.match(ln.text)
        bg, o, nn = '', '', ''
        if m:
            old, new = int(m.group(1)), int(m.group(2)); bg = th['hunkbg']; col = th['hunk']
        elif ln.text.startswith('+'):
            nn = str(new); new += 1; bg = th['addbg']; col = th['fg']
        elif ln.text.startswith('-'):
            o = str(old); old += 1; bg = th['rembg']; col = th['fg']
        else:
            o, nn = str(old), str(new); old += 1; new += 1; col = th['fg']
        nums += [x for x in (o, nn) if x]
        rows.append(f'<div style="display:flex;background:{bg}"><div style="width:46px;flex:none;text-align:right;padding-right:8px;color:{th["dim"]};background:{th["gut"]}">{o}</div>'
                    f'<div style="width:46px;flex:none;text-align:right;padding-right:8px;color:{th["dim"]};background:{th["gut"]}">{nn}</div>'
                    f'<div style="flex:1;min-width:0;white-space:pre-wrap;overflow-wrap:anywhere;padding-left:10px;color:{col}">{html.escape(ln.text) if m else highlight(ln.text, "swift", th)}</div></div>')
    gutter['text'] = ' '.join(nums)
    table = (f'<div style="margin:0 32px 0;border:1px solid {th["edge"]};border-top:0;font:12px {th["mono"]};line-height:19px;overflow:hidden">{"".join(rows)}</div>')
    comments = ''
    for who, when, blocks in rv['comments']:
        doc.unit(who, opt=True, reason='name', kind='name')
        doc.unit(when, opt=True, reason='number', kind='time')
        inner = ''.join(block_md(doc, th, b, sc) for b in blocks)
        comments += (f'<div style="margin:14px 32px;border:1px solid {th["edge"]};border-radius:6px"><div style="background:{th["bar"]};padding:8px 14px;font-size:13px;color:{th["dim"]}">'
                     f'<b style="color:{th["fg"]}">{html.escape(who)}</b> {html.escape(when)}</div><div style="padding:2px 14px 8px;font-size:14px">{inner}</div></div>')
    ctitle = ui_text(doc, rv['commits_title'], 'commits-title')
    crows = ''
    for h, summary in rv['commits']:
        doc.unit(h, keep=True, reason='hash', kind='hash')
        crows += (f'<div style="padding:7px 0;border-bottom:1px solid {th["edge"]};font-size:13px"><span style="font:12px {th["mono"]};color:{th["link"]}">{h}</span>'
                  f'<div style="margin-top:2px">{para(doc, th, summary, "commit")}</div></div>')
    panel = (f'<div style="width:330px;flex:none;padding:0 32px 0 0"><div style="font-size:13px;font-weight:700;padding:6px 0;color:{th["dim"]}">{ctitle}</div>{crows}</div>')
    left = f'<div style="flex:1;min-width:0">{fhead}{table}{comments}</div>'
    return h2.page(th, WIDTH['review'], head + f'<div style="display:flex;gap:28px">{left}{panel}</div><div style="height:26px"></div>')


# ------------------------------------------------------------------------------------------------------------------------- card
def look_card(doc, sc, th, _boxed):
    """Notification-sized cards on a desktop: app name and time, a title, a body with inline pieces, optional code lines, action buttons."""
    out = []
    for c in sc['cards']:
        doc.unit(c['app'], opt=True, reason='name', kind='app')
        doc.unit(c['time'], opt=True, reason='number', kind='time')
        inner = (f'<div style="display:flex;gap:10px;align-items:center;font-size:12px;color:{th["dim"]};text-transform:uppercase;letter-spacing:.4px">'
                 f'<i style="display:inline-block;width:20px;height:20px;border-radius:5px;background:{c.get("color", "#e8912d")}"></i>'
                 f'<span style="flex:1">{html.escape(c["app"])}</span><span>{html.escape(c["time"])}</span></div>')
        inner += f'<div style="font-weight:700;font-size:15px;margin:9px 0 3px">{para(doc, th, c["title"], "heading")}</div>'
        inner += f'<div style="font-size:14px;line-height:1.45">{para(doc, th, c["body"])}</div>'
        if c.get('code'):
            region = doc.region()
            rows = emit_lines(doc, th, h2.Listing(c['code'], c.get('lang', 'term')), region, 17)
            inner += (f'<div style="margin-top:9px;background:{th["box"]};border:1px solid {th["edge"]};border-radius:8px;padding:8px 11px;'
                      f'font:12px {th["mono"]}">{rows}</div>')
        if c.get('actions'):
            btn = ''.join(f'<span style="border:1px solid {th["edge"]};border-radius:7px;padding:3px 13px;font-size:13px">{ui_text(doc, a, "action")}</span>' for a in c['actions'])
            inner += f'<div style="display:flex;gap:8px;margin-top:11px">{btn}</div>'
        out.append(f'<div style="background:{th["cardbg"]};border:1px solid {th["edge"]};border-radius:16px;padding:13px 16px 14px;margin:0 0 12px;'
                   f'box-shadow:0 4px 14px rgba(0,0,0,.18)">{inner}</div>')
    return h2.page(th, WIDTH['card'], f'<div style="padding:18px 20px 8px">{"".join(out)}</div>')


LOOKS.update({'pane': look_pane, 'docs': look_docs, 'review': look_review, 'card': look_card})
