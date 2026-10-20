#!/usr/bin/env python3
"""What a sequence of `Mwoyeo --mcp` calls costs an agent's context (round mcp2, 2026-10-21).

usage: tools/mcp/budget.py <Mwoyeo binary> <scratch dir> <transcripts folder or one .jsonl> <calls.json> [--settings-from <file>]

calls.json is a list of {"tool": ..., "arguments": {...}}, run in order against one server over a scratch copy of the log. For each call it
prints the bytes of the result the agent reads and the bytes of the whole reply line on the wire, then the totals and the size of tools/list
and the initialize `instructions`.

WHICH COPY THE AGENT READS (measured 2026-10-21, Claude Code 2.1.304, /tmp/mcp2/probe): with `structuredContent` in a result the client hands
the model JSON.stringify(structuredContent) and ignores the text block; without it, the text block. So "read by the agent" is the structured
copy when the reply has one, else the first text block. A reply that carries both costs its wire bytes twice for a client that reads both.

FAILURE MODE IT BLOCKS: a change that makes a tool's answer grow unseen (a field repeated per row, a payload sent twice). Nothing here
touches the user's settings or transcripts: the log is copied into the scratch dir, and every run carries MWOYEO_SETTINGS_FILE,
MWOYEO_DEFAULTS_SUITE and MWOYEO_MEMORY_SECRETS=1.
"""
import json
import os
import shutil
import subprocess
import sys


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 4:
        sys.exit(__doc__)
    binary, scratch, log, calls_file = args
    os.makedirs(scratch, exist_ok=True)
    export = os.path.join(scratch, 'export')
    transcripts = os.path.join(export, 'Transcripts')
    shutil.rmtree(export, ignore_errors=True)
    os.makedirs(transcripts)
    if os.path.isdir(log):
        for name in os.listdir(log):
            if name.endswith('.jsonl'):
                shutil.copy(os.path.join(log, name), transcripts)
    else:
        shutil.copy(log, transcripts)
    settings = os.path.join(scratch, 'settings.json')
    with open(settings, 'w', encoding='utf-8') as f:
        json.dump({'sourceLanguage': 'ja', 'targetLanguage': 'ko', 'savesTranscripts': True, 'exportFolder': export,
                   'transcriptFormats': ['jsonl'], 'agentConnection': True}, f)
    env = dict(os.environ, MWOYEO_SETTINGS_FILE=settings, MWOYEO_DEFAULTS_SUITE='mcp.budget.%d' % os.getpid(), MWOYEO_MEMORY_SECRETS='1')

    calls = json.load(open(calls_file, encoding='utf-8'))
    messages = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'budget', 'version': '1'}}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}]
    for i, c in enumerate(calls):
        messages.append({'jsonrpc': '2.0', 'id': 10 + i, 'method': 'tools/call', 'params': {'name': c['tool'], 'arguments': c.get('arguments', {})}})
    out = subprocess.run([binary, '--mcp'], input=''.join(json.dumps(m, ensure_ascii=False) + '\n' for m in messages),
                         capture_output=True, encoding='utf-8', env=env, timeout=300)
    replies = {}
    for line in out.stdout.split('\n'):
        if line:
            r = json.loads(line)
            replies[r.get('id')] = (r, len(line.encode('utf-8')))

    def size(value):
        return len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))

    init, init_wire = replies[1]
    listed, listed_wire = replies[2]
    print('initialize: instructions %d bytes, reply %d bytes' % (len(init['result'].get('instructions', '').encode('utf-8')), init_wire))
    print('tools/list: %d tools, reply %d bytes' % (len(listed['result']['tools']), listed_wire))
    total_read = total_wire = 0
    for i, c in enumerate(calls):
        reply, wire = replies[10 + i]
        result = reply.get('result', {})
        text = (result.get('content') or [{}])[0].get('text', '')
        if 'structuredContent' in result:
            read, which = size(result['structuredContent']), 'structuredContent'
        else:
            read, which = len(text.encode('utf-8')), 'text'
        flag = ' ERROR' if result.get('isError') else ''
        print('call %-22s read %6d bytes (%s)  wire %6d bytes%s  %s' % (c['tool'], read, which, wire, flag,
                                                                     json.dumps(c.get('arguments', {}), ensure_ascii=False)[:70]))
        if result.get('isError'):
            print('    ' + text[:300])
        total_read += read
        total_wire += wire
    print('total: read %d bytes, wire %d bytes' % (total_read, total_wire))
    if out.returncode != 0:
        print('server exit code %d' % out.returncode)


main()
