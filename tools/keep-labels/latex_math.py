#!/usr/bin/env python3
"""Inline and display mathematics of a paper's LaTeX source (an arXiv e-print): what the author marked as `$..$`, `\\(..\\)` and
`\\begin{math}` (inline), and `$$..$$`, `\\[..\\]` and the equation environments (display).
usage: latex_math.py <e-print file> [--spans]        prints one JSON object: {"inline":N,"display":M,"files":[..],"spans":[..]}
The source is read from the e-print without unpacking it (tar.gz of files, or one gzipped .tex), `\\input` / `\\include` expanded in
place, everything before \\begin{document} and every comment dropped, macro definitions skipped. It is the truth for how many
inline formulas a paper has (the glyph truth in label.py is checked against it), not for where they are."""
import gzip, io, json, re, sys, tarfile

DISPLAY_ENVS = {'equation', 'equation*', 'align', 'align*', 'alignat', 'alignat*', 'eqnarray', 'eqnarray*', 'gather', 'gather*',
                'multline', 'multline*', 'displaymath', 'flalign', 'flalign*', 'split', 'subequations'}
VERBATIM_ENVS = {'verbatim', 'verbatim*', 'lstlisting', 'minted', 'comment'}

def read_files(path):
    raw = open(path, 'rb').read()
    try:
        data = gzip.decompress(raw)
    except OSError:
        data = raw
    files = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            for m in t.getmembers():
                if m.isfile() and m.name.endswith('.tex'):
                    files[m.name.lstrip('./')] = t.extractfile(m).read().decode('utf-8', 'replace')
    except tarfile.TarError:
        files['main.tex'] = data.decode('utf-8', 'replace')
    return files

def strip_comments(s):
    out = []
    for line in s.split('\n'):
        i = 0
        while True:
            i = line.find('%', i)
            if i < 0: break
            k = i
            while k > 0 and line[k - 1] == '\\': k -= 1
            if (i - k) % 2 == 0: line = line[:i]; break
            i += 1
        out.append(line)
    return '\n'.join(out)

def expand(files, name, seen=()):
    s = strip_comments(files[name])
    def sub(m):
        t = m.group(2).strip()
        for cand in (t, t + '.tex'):
            if cand in files and cand not in seen:
                return expand(files, cand, seen + (name,))
        return ''
    return re.sub(r'\\(input|include)\s*\{([^}]*)\}', sub, s)

def main_file(files):
    for n, s in sorted(files.items()):
        if '\\begin{document}' in s: return n
    return sorted(files)[0]

def skip_group(s, i):
    """s[i] == '{': index after the matching '}'."""
    d = 0
    while i < len(s):
        if s[i] == '\\': i += 2; continue
        if s[i] == '{': d += 1
        elif s[i] == '}':
            d -= 1
            if d == 0: return i + 1
        i += 1
    return i

def drop_definitions(s):
    out, i = [], 0
    pat = re.compile(r'\\(?:re)?newcommand\*?|\\providecommand\*?|\\DeclareMathOperator\*?|\\newenvironment\*?|\\def\b|\\newcommandx')
    while True:
        m = pat.search(s, i)
        if not m: out.append(s[i:]); break
        out.append(s[i:m.start()])
        j = m.end()
        # name, optional [n] / [d], then the body group(s)
        while j < len(s) and s[j] in ' \n\t': j += 1
        if j < len(s) and s[j] == '{': j = skip_group(s, j)
        elif j < len(s) and s[j] == '\\': j = re.compile(r'\\[A-Za-z@]+|\\.').match(s, j).end()
        while j < len(s) and s[j] in ' \n\t#0123456789': j += 1
        while j < len(s) and s[j] == '[':
            j = s.index(']', j) + 1
            while j < len(s) and s[j] in ' \n\t': j += 1
        if j < len(s) and s[j] == '{': j = skip_group(s, j)
        if m.group(0).startswith('\\newenv'):
            while j < len(s) and s[j] in ' \n\t': j += 1
            if j < len(s) and s[j] == '{': j = skip_group(s, j)
        i = j
    return ''.join(out)

def math_spans(s):
    """-> list of (kind, text) in document order; kind 'inline' | 'display'."""
    s = s[s.find('\\begin{document}'):] if '\\begin{document}' in s else s
    s = drop_definitions(s)
    found, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '\\':
            if s.startswith('\\(', i):
                j = s.find('\\)', i + 2)
                if j < 0: break
                found.append(('inline', s[i + 2:j])); i = j + 2; continue
            if s.startswith('\\[', i):
                j = s.find('\\]', i + 2)
                if j < 0: break
                found.append(('display', s[i + 2:j])); i = j + 2; continue
            m = re.compile(r'\\(begin|end)\{([^}]*)\}').match(s, i)
            if m and m.group(1) == 'begin':
                env = m.group(2)
                if env in VERBATIM_ENVS or env in DISPLAY_ENVS or env == 'math':
                    endtag = '\\end{' + env + '}'
                    j = s.find(endtag, m.end())
                    if j < 0: break
                    kind = 'inline' if env == 'math' else 'display'
                    if env not in VERBATIM_ENVS: found.append((kind, s[m.end():j]))
                    i = j + len(endtag); continue
            if s.startswith('\\verb', i) and i + 5 < n:
                d = s[i + 5]; j = s.find(d, i + 6); i = (j + 1) if j > 0 else i + 5; continue
            i += 2; continue
        if c == '$':
            if s.startswith('$$', i):
                j = s.find('$$', i + 2)
                if j < 0: break
                found.append(('display', s[i + 2:j])); i = j + 2; continue
            j = i + 1
            while j < n:
                if s[j] == '\\': j += 2; continue
                if s[j] == '$': break
                j += 1
            if j >= n: break
            found.append(('inline', s[i + 1:j])); i = j + 1; continue
        i += 1
    return found

def analyse(path):
    files = read_files(path)
    main = main_file(files)
    text = expand(files, main)
    spans = math_spans(text)
    return {'main': main, 'files': sorted(files), 'inline': sum(1 for k, _ in spans if k == 'inline'),
            'display': sum(1 for k, _ in spans if k == 'display'), 'spans': [[k, re.sub(r'\s+', ' ', t.strip())] for k, t in spans]}

if __name__ == '__main__':
    r = analyse(sys.argv[1])
    if '--spans' not in sys.argv: del r['spans']
    print(json.dumps(r, ensure_ascii=False))
