#!/bin/bash
# Process smoke test of `Mwoyeo --mcp` (round mcp1, 2026-10-20; round mcp2, 2026-10-21): the built binary, a scratch settings.json and a
# scratch Transcripts folder, JSON-RPC lines on its stdin. check-logic drives the same server in process (App/Support/MCPChecks.swift);
# this is what only a process shows. translate_text runs here against tools/mock-openai/server.py (the kind of engine a lens uses) and
# against Apple Translation (a translation when the pair's pack is installed, else the pack's refusal): its work waits on the main run loop.
#
# usage: tools/mcp/smoke.sh <Mwoyeo binary> [scratch dir]        env SMOKE_TIMEOUT=<seconds> (default 60): the bound on one server run
# FAILURE MODES IT BLOCKS: anything but protocol on stdout (a print left in a path the server reaches); a server that does not end at the
# EOF of stdin (the run is bounded by SMOKE_TIMEOUT, which only fires when it fails); a settings.json the server writes that the app's own
# `--check-settings` refuses; the switch (agentConnection) not read at each call; an unknown method that is not -32601; a rejected call
# that wrote something; no trace line on stderr for a message; a result that carries its payload twice (structuredContent beside the
# text); translate_text that never returns (the main thread waiting on work that needs the run loop) or that leaves the memory out.
# Every run carries MWOYEO_SETTINGS_FILE, MWOYEO_DEFAULTS_SUITE and MWOYEO_MEMORY_SECRETS=1: the user's settings and transcripts are never read.
set -u
BIN=${1:?usage: tools/mcp/smoke.sh <Mwoyeo binary> [scratch dir]}
D=${2:-$(mktemp -d /tmp/mcp-smoke.XXXXXX)}
mkdir -p "$D"
export MWOYEO_SETTINGS_FILE="$D/settings.json" MWOYEO_DEFAULTS_SUITE="mcp.smoke.$$" MWOYEO_MEMORY_SECRETS=1

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
python3 -I - "$BIN" "$D" "${SMOKE_TIMEOUT:-60}" "$ROOT" <<'PY'
import json, os, socket, subprocess, sys, time

binary, scratch, limit, root = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
settings = os.path.join(scratch, 'settings.json')
export = os.path.join(scratch, 'export')
failures = 0


def check(what, ok):
    global failures
    print('smoke: %s %s' % ('PASS' if ok else 'FAIL', what))
    if not ok:
        failures += 1


def write_settings(on):
    body = {'sourceLanguage': 'ja', 'targetLanguage': 'ko', 'savesTranscripts': True, 'exportFolder': export, 'transcriptFormats': ['jsonl']}
    if on:
        body['agentConnection'] = True
    with open(settings, 'w', encoding='utf-8') as f:
        json.dump(body, f, indent=2)
        f.write('\n')


def serve(messages):
    """One server run: the messages on stdin, then EOF. Returns (exit code, replies by id, stderr), or None when it did not end."""
    text = ''.join(json.dumps(m, ensure_ascii=False) + '\n' for m in messages)
    try:
        p = subprocess.run([binary, '--mcp'], input=text, capture_output=True, timeout=limit, encoding='utf-8')
    except subprocess.TimeoutExpired:
        return None
    replies, strays = {}, []
    for line in p.stdout.split('\n'):
        if not line:
            continue
        try:
            reply = json.loads(line)
        except ValueError:
            reply = None
        if not isinstance(reply, dict) or reply.get('jsonrpc') != '2.0':
            strays.append(line)
            continue
        replies[reply.get('id')] = reply
    return p.returncode, replies, p.stderr, strays


def request(i, method, params=None):
    m = {'jsonrpc': '2.0', 'id': i, 'method': method}
    if params is not None:
        m['params'] = params
    return m


def call(i, tool, **arguments):
    return request(i, 'tools/call', {'name': tool, 'arguments': arguments})


def result(replies, i):
    return replies.get(i, {}).get('result', {})


def text(replies, i):
    content = result(replies, i).get('content') or [{}]
    return content[0].get('text', '')


def payload(replies, i):
    """The one copy of a result: its text block read as JSON ({} for an error or text that is not JSON)."""
    if result(replies, i).get('isError'):
        return {}
    try:
        return json.loads(text(replies, i))
    except ValueError:
        return {}


def column(table, name):
    """One column of a table result (columns + rows)."""
    columns = table.get('columns', [])
    return [row[columns.index(name)] for row in table.get('rows', [])] if name in columns else []


# A log of one line, in the format the app's writer gives (TranscriptFormat.jsonlLine).
os.makedirs(os.path.join(export, 'Transcripts'), exist_ok=True)
with open(os.path.join(export, 'Transcripts', 'Chat 2026-10-20 09-00.jsonl'), 'w', encoding='utf-8') as f:
    row = [('time', '2026-10-20T09:00:01.000+09:00'), ('lens', 'Chat'), ('app', 'com.example.smoke'), ('source', 'ja'), ('target', 'ko'),
           ('engine', 'apple'), ('original', '九十九が来た'), ('translation', '쓰쿠모가 왔다')]
    f.write(json.dumps(dict(row), ensure_ascii=False) + '\n')

# The switch on: the handshake, the four kinds of tool, a rejected write, an unknown method
write_settings(True)
entries = [{'src': '九十九', 'dst': 'Tsukumo', 'kind': 'person'}, {'src': '魔王城', 'dst': "Demon King's Castle", 'kind': 'place'}]
messages = [
    request(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'smoke', 'version': '1'}}),
    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    request(2, 'tools/list'),
    call(3, 'list_apps'),
    call(4, 'read_translation_log', app='com.example.smoke'),
    call(5, 'set_memory', app='com.example.smoke', note='Fantasy RPG.', entries=entries),
    call(6, 'get_memory', app='com.example.smoke'),
    call(7, 'get_settings', keys=['targetLanguage', 'agentConnection']),
    call(8, 'set_settings', values={'lensStyle': 'subtle'}),
    call(9, 'set_settings', values={'agentConnection': False}),
    request(10, 'resources/list'),
    call(11, 'get_settings_schema'),
    call(12, 'term_renderings', app='com.example.smoke', terms=['九十九', '無い']),
    call(13, 'get_settings_schema', key='glossary'),
    call(14, 'translate_text', lines=['おはようございます'], engine='apple'),
]
ran = serve(messages)
check('the server ends at the EOF of stdin (bound %ds)' % limit, ran is not None)
if ran is not None:
    code, replies, stderr, strays = ran
    check('exit code 0 at EOF', code == 0)
    check('stdout holds protocol and nothing else (%d stray line(s))' % len(strays), not strays)
    check('every request is answered once, the notification not at all', sorted(replies) == list(range(1, 15)))
    check('no result carries a structuredContent beside its text, and each has one text block',
          all('structuredContent' not in result(replies, i) and len(result(replies, i).get('content', [])) == 1 for i in range(3, 15) if i != 10))
    init = result(replies, 1)
    check('initialize: protocol 2025-06-18, tools capability, name mwoyeo',
          init.get('protocolVersion') == '2025-06-18' and 'tools' in init.get('capabilities', {}) and init.get('serverInfo', {}).get('name') == 'mwoyeo')
    names = [t['name'] for t in result(replies, 2).get('tools', [])]
    check('tools/list: the nine tools', names == ['list_apps', 'read_translation_log', 'term_renderings', 'get_memory', 'set_memory', 'translate_text',
                                                   'get_settings', 'set_settings', 'get_settings_schema'])
    apps = payload(replies, 3)
    check('list_apps reads the scratch log', [a.get('bundleID') for a in apps.get('loggedApps', [])] == ['com.example.smoke'])
    log = payload(replies, 4)
    check('read_translation_log returns the line of the scratch log, its constant fields in the header',
          column(log, 'original') == ['九十九が来た'] and log.get('app') == 'com.example.smoke' and log.get('engine') == 'apple' and log.get('zone') == '+09:00'
          and column(log, 'time') == ['09:00:01'])
    stored = payload(replies, 5)
    check('set_memory creates the profile on the base languages', result(replies, 5).get('isError') is None and stored.get('created') is True
          and stored.get('source') == 'ja' and stored.get('target') == 'ko')
    got = payload(replies, 6)
    check('get_memory returns what set_memory stored', got.get('note') == 'Fantasy RPG.' and [e.get('src') for e in got.get('entries', [])] == ['九十九', '魔王城'])
    shown = payload(replies, 7).get('settings', {})
    check('get_settings returns the named keys', shown == {'targetLanguage': 'ko', 'agentConnection': True})
    check('set_settings applies a valid key', payload(replies, 8).get('applied') == {'lensStyle': 'subtle'})
    check('set_settings refuses agentConnection', result(replies, 9).get('isError') is True and 'cannot be changed through MCP' in text(replies, 9))
    check('an unknown method is -32601', replies.get(10, {}).get('error', {}).get('code') == -32601)
    check('get_settings_schema returns the schema', 'agentConnection' in payload(replies, 11).get('properties', {}))
    terms = payload(replies, 12)
    check('term_renderings: the translation of the name in the scratch log, and a term that is not there with none',
          [t.get('term') for t in terms.get('terms', [])] == ['九十九', '無い'] and terms['terms'][0]['renderings'] == [[1, '쓰쿠모가 왔다', [1]]] and terms['terms'][1]['renderings'] == [])
    keyed = payload(replies, 13)
    check('get_settings_schema with a key returns that setting alone', keyed.get('key') == 'glossary' and keyed.get('schema', {}).get('type') == 'string' and len(text(replies, 13)) < 1000)
    # Apple Translation, ja -> ko, is a translation when its pack is installed here and the pack's refusal when not; either way the call returns.
    apple = payload(replies, 14)
    refused = result(replies, 14).get('isError') is True and ('language pack' in text(replies, 14) or 'not supported' in text(replies, 14))
    print('smoke: note translate_text with Apple said: %s' % (text(replies, 14)[:160]))
    check('translate_text with Apple returns: a translation, or the language pack refusal',
          (apple.get('columns') == ['translation', 'engine'] and len(apple.get('rows', [])) == 1 and isinstance(apple['rows'][0][0], str)
           and apple['rows'][0][1] == 'Apple') or refused)
    traced = [l for l in stderr.split('\n') if l.startswith('mcp: ')]
    check('stderr traces every message (%d lines)' % len(traced), len(traced) >= len(messages))
    check('stderr does not carry the text of a note or a name', 'Fantasy' not in stderr and '九十九' not in stderr)

checked = subprocess.run([binary, '--check-settings', settings], capture_output=True, encoding='utf-8')
check('--check-settings says ok on the file the server wrote', checked.returncode == 0 and checked.stdout == 'ok\n')

# A rejected write writes nothing
before = open(settings, 'rb').read()
bad = serve([call(1, 'set_memory', app='com.example.smoke', entries=[{'src': 'a', 'dst': 'b', 'kind': 'villain'}]),
             call(2, 'set_settings', values={'lensStyle': 'neon'})])
check('rejected calls name their path', bad is not None and 'entries[0].kind' in text(bad[1], 1) and 'values.lensStyle' in text(bad[1], 2))
check('and write nothing', open(settings, 'rb').read() == before)

# Command engines are the person's; other engines an agent may add
engine = {'id': '5B1F3C0A-6D2E-4E0B-9A41-0C7D2A9E1F11', 'name': 'Local', 'kind': 'openAICompatible', 'baseURL': 'http://localhost:11434/v1', 'model': 'gemma3:4b'}
program = {'name': 'Mine', 'kind': 'command', 'command': {'executable': '/usr/bin/true'}}
refusal = serve([call(1, 'set_settings', values={'engines': [program]})])
check('set_settings refuses a command engine', refusal is not None and result(refusal[1], 1).get('isError') is True
      and 'Command engines are added by the person in Settings.' in text(refusal[1], 1))
check('and writes nothing', open(settings, 'rb').read() == before)
added = serve([call(1, 'set_settings', values={'engines': [engine]})])
check('set_settings adds an openAICompatible engine', added is not None and payload(added[1], 1).get('applied', {}).get('engines', [{}])[0].get('kind') == 'openAICompatible')
checked = subprocess.run([binary, '--check-settings', settings], capture_output=True, encoding='utf-8')
check('--check-settings says ok with the engine in the file', checked.returncode == 0 and checked.stdout == 'ok\n')

# translate_text against an engine of the lens's kind: a mock OpenAI-compatible server on a free port. The memory of the app must be in what
# the engine is sent, and the answer names the engine that made the line.
def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


mock_script = os.path.join(root, 'tools', 'mock-openai', 'server.py')
dump = os.path.join(scratch, 'mock-dump')
port = free_port()
mock = subprocess.Popen(['python3', '-I', mock_script, str(port), 'ok', 'native', '--dump', dump], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ready = False
    for _ in range(100):
        try:
            socket.create_connection(('127.0.0.1', port), timeout=0.5).close()
            ready = True
            break
        except OSError:
            time.sleep(0.05)
    check('the mock engine server starts', ready)
    if ready:
        engine_id = '5B1F3C0A-6D2E-4E0B-9A41-0C7D2A9E1F11'
        body = {'sourceLanguage': 'en', 'targetLanguage': 'ko', 'agentConnection': True, 'customEngineID': engine_id,
                'engines': [{'id': engine_id, 'name': 'Mock', 'kind': 'openAICompatible', 'baseURL': 'http://127.0.0.1:%d/v1' % port, 'model': 'm1'}],
                'appProfiles': [{'bundleID': 'com.example.chat', 'appName': 'Example Chat', 'source': 'en', 'target': 'ko', 'note': 'casual chat between friends',
                                 'entries': [{'src': 'Alice', 'dst': '앨리스', 'kind': 'person'}]}]}
        with open(settings, 'w', encoding='utf-8') as f:
            json.dump(body, f, indent=2)
            f.write('\n')
        before_files = set(os.listdir(dump)) if os.path.isdir(dump) else set()
        talk = serve([call(1, 'translate_text', lines=['Alice sent a photo'], app='com.example.chat'), call(2, 'translate_text', lines=['Alice sent another photo'])])
        check('translate_text returns (the process does not hang on the main thread)', talk is not None)
        if talk is not None:
            first, second = payload(talk[1], 1), payload(talk[1], 2)
            sent = sorted(set(os.listdir(dump)) - before_files) if os.path.isdir(dump) else []
            bodies = [open(os.path.join(dump, n), encoding='utf-8').read() for n in sent]
            check('translate_text through the mock engine: the translation, the engine named, and the app memory used',
                  column(first, 'engine') == ['Mock'] and 'Alice sent a photo' in (column(first, 'translation') or [''])[0] and first.get('memory') == 'used')
            check('and the memory was in what the engine was sent, for the call with the app only',
                  len(bodies) == 2 and '앨리스' in bodies[0] and 'casual chat between friends' in bodies[0] and '앨리스' not in bodies[1])
            check('translate_text without an app: no memory is claimed', column(second, 'engine') == ['Mock'] and 'memory' not in second)
finally:
    mock.terminate()
    mock.wait()

# The switch off: the handshake answers, every tool call is refused, nothing is written
write_settings(False)
before = open(settings, 'rb').read()
off = serve([request(1, 'initialize', {}), request(2, 'tools/list'), call(3, 'list_apps'), call(4, 'set_memory', app='com.example.smoke', note='x'),
             call(5, 'set_settings', values={'lensStyle': 'glow'})])
check('switch off: initialize and tools/list answer', off is not None and 'protocolVersion' in result(off[1], 1) and len(result(off[1], 2).get('tools', [])) == 9)
check('switch off: every tool call is refused', off is not None and all(result(off[1], i).get('isError') is True and text(off[1], i).startswith('Agent connection is off.') for i in (3, 4, 5)))
check('switch off: nothing is written', open(settings, 'rb').read() == before)

print('smoke: %s' % ('all passed' if failures == 0 else '%d FAILED' % failures))
sys.exit(1 if failures else 0)
PY
