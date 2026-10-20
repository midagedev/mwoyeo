#!/usr/bin/env python3
"""A pass-through in front of an OpenAI-compatible server that keeps every request and reply, byte for byte.
Run it isolated: `python3 -I tap.py --upstream http://127.0.0.1:11434 --dump DIR [--port N] [--port-file F]`
It listens on a local port (--port, or a free one; written to --port-file once it listens), forwards each request unchanged to --upstream, and writes
DIR/<nnnn>.request.json and DIR/<nnnn>.reply.json (nnnn counts the POSTs from 0001; a GET is forwarded and not kept). It changes nothing the engine or the app sees, so a render
behind it is the render without it; it exists so that a plate can show what the engine was sent (the note, the names) and was answered.
Prints one line per request to stderr: the number, the path, the reply status, the bytes."""
import argparse
import http.client
import itertools
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
COUNT = itertools.count(1)
LOCK = threading.Lock()


def make_handler(upstream, dump):
    up = urlsplit(upstream)

    class Tap(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def relay(self, body):
            n = 0
            if body is not None:      # a GET (the readiness probe, /v1/models) is forwarded and not kept
                with LOCK:
                    n = next(COUNT)
                with open(os.path.join(dump, "%04d.request.json" % n), "wb") as f:
                    f.write(body)
            # An https upstream (the Anthropic API) is reached over TLS; the request headers (the key) are forwarded, never written.
            conn = (http.client.HTTPSConnection(up.hostname, up.port or 443, timeout=900) if up.scheme == "https"
                    else http.client.HTTPConnection(up.hostname, up.port or 80, timeout=900))
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length")}
            conn.request(self.command, self.path, body=body, headers=headers)
            r = conn.getresponse()
            data = r.read()
            if body is not None:
                with open(os.path.join(dump, "%04d.reply.json" % n), "wb") as f:
                    f.write(data)
            self.send_response(r.status)
            self.send_header("Content-Type", r.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            print("%04d %s %d %d bytes" % (n, self.path, r.status, len(data)), file=sys.stderr, flush=True)

        def do_POST(self):
            self.relay(self.rfile.read(int(self.headers.get("Content-Length", "0"))))

        def do_GET(self):
            self.relay(None)

    return Tap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--dump", required=True)
    ap.add_argument("--port", type=int, default=0, help="the port to listen on (default: a free one)")
    ap.add_argument("--port-file", help="where to write the port once it listens")
    a = ap.parse_args()
    os.makedirs(a.dump, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(a.upstream, a.dump))
    if a.port_file:
        tmp = a.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write(str(server.server_address[1]))
        os.replace(tmp, a.port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
