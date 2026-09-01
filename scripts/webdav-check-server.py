#!/usr/bin/env python3
"""A small WebDAV server for the device checks of the backup tickets.

It answers the six methods Empo sends: PROPFIND, PUT, GET, DELETE,
MKCOL, and MOVE. SPEC 8.11 takes an https address only, so the server
needs a certificate and a key. `--quota` makes it answer the space
query of RFC 4331. Without that flag it answers the two quota
properties in a 404 block, the way a server without the query does.

    python3 scripts/webdav-check-server.py --root /tmp/dav-a \\
        --port 8443 --cert /tmp/dav-cert/server.pem \\
        --key /tmp/dav-cert/server.key --user alice --password s3cret

The Empo address for the command above is https://localhost:8443/dav.
"""

import argparse
import base64
import email.utils
import os
import posixpath
import shutil
import ssl
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = "/dav"

CONFIG = {}


def http_date(seconds):
    return email.utils.formatdate(seconds, usegmt=True)


class Handler(BaseHTTPRequestHandler):

    protocol_version = "HTTP/1.1"
    server_version = "EmpoCheckDAV/1"

    # MARK: the file map

    def local_path(self, request_path):
        """The file this address names, or None when it leaves the root."""
        path = urllib.parse.unquote(request_path.split("?")[0])
        if not path.startswith(BASE):
            return None
        rest = path[len(BASE):].strip("/")
        root = CONFIG["root"]
        if not rest:
            return root
        found = os.path.normpath(os.path.join(root, rest))
        if found != root and not found.startswith(root + os.sep):
            return None
        return found

    def href(self, local, is_collection):
        rest = os.path.relpath(local, CONFIG["root"])
        parts = [] if rest == "." else rest.split(os.sep)
        text = BASE + "".join("/" + urllib.parse.quote(part) for part in parts)
        return text + "/" if is_collection else text

    # MARK: the answers

    def answer(self, status, body=b"", headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def authorized(self):
        pair = "%s:%s" % (CONFIG["user"], CONFIG["password"])
        wanted = "Basic " + base64.b64encode(pair.encode()).decode()
        if self.headers.get("Authorization") == wanted:
            return True
        self.answer(401, b"", {"WWW-Authenticate": 'Basic realm="empo"'})
        return False

    # MARK: the methods

    def refuses(self):
        """Whether the switch file makes the server answer 503.

        A check that needs two devices apart needs a server that
        answers and refuses. A server that is down instead leaves the
        upload of Empo waiting on its background session for minutes.
        """
        if not CONFIG["switch"] or not os.path.exists(CONFIG["switch"]):
            return False
        self.answer(503, b"", {"Retry-After": "1"})
        return True

    def do_OPTIONS(self):
        self.answer(
            200,
            b"",
            {
                "DAV": "1, 2",
                "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL, MOVE",
            },
        )

    def do_GET(self):
        if not self.authorized() or self.refuses():
            return
        local = self.local_path(self.path)
        if not local or not os.path.isfile(local):
            return self.answer(404)
        with open(local, "rb") as handle:
            body = handle.read()
        self.answer(200, body, {"Content-Type": "application/octet-stream"})

    do_HEAD = do_GET

    def do_PUT(self):
        if not self.authorized() or self.refuses():
            return
        body = self.read_body()
        local = self.local_path(self.path)
        if not local:
            return self.answer(403)
        if not os.path.isdir(os.path.dirname(local)):
            return self.answer(409)
        existed = os.path.isfile(local)
        with open(local, "wb") as handle:
            handle.write(body)
        self.answer(204 if existed else 201)

    def do_DELETE(self):
        if not self.authorized() or self.refuses():
            return
        local = self.local_path(self.path)
        if not local or not os.path.exists(local):
            return self.answer(404)
        if os.path.isdir(local):
            shutil.rmtree(local)
        else:
            os.remove(local)
        self.answer(204)

    def do_MKCOL(self):
        if not self.authorized() or self.refuses():
            return
        local = self.local_path(self.path)
        if not local:
            return self.answer(403)
        if os.path.exists(local):
            return self.answer(405)
        if not os.path.isdir(os.path.dirname(local)):
            return self.answer(409)
        os.mkdir(local)
        self.answer(201)

    def do_MOVE(self):
        if not self.authorized() or self.refuses():
            return
        source = self.local_path(self.path)
        target = self.headers.get("Destination") or ""
        target = self.local_path(urllib.parse.urlsplit(target).path)
        if not source or not os.path.exists(source):
            return self.answer(404)
        if not target:
            return self.answer(403)
        if not os.path.isdir(os.path.dirname(target)):
            return self.answer(409)
        existed = os.path.exists(target)
        if existed:
            if (self.headers.get("Overwrite") or "T").upper() != "T":
                return self.answer(412)
            os.remove(target) if os.path.isfile(target) else shutil.rmtree(target)
        os.replace(source, target)
        self.answer(204 if existed else 201)

    def do_PROPFIND(self):
        if not self.authorized() or self.refuses():
            return
        body = self.read_body().decode("utf-8", "replace")
        local = self.local_path(self.path)
        if not local or not os.path.exists(local):
            return self.answer(404)
        if "quota-available-bytes" in body:
            return self.answer(207, self.quota_answer(local).encode(), self.xml_headers())

        blocks = [self.entry(local)]
        if (self.headers.get("Depth") or "1") != "0" and os.path.isdir(local):
            for name in sorted(os.listdir(local)):
                blocks.append(self.entry(os.path.join(local, name)))
        text = self.multistatus("".join(blocks))
        self.answer(207, text.encode(), self.xml_headers())

    def xml_headers(self):
        return {"Content-Type": 'application/xml; charset="utf-8"'}

    def multistatus(self, inner):
        return (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<D:multistatus xmlns:D="DAV:">%s</D:multistatus>' % inner
        )

    def entry(self, local):
        is_collection = os.path.isdir(local)
        stat = os.stat(local)
        kind = "<D:collection/>" if is_collection else ""
        size = 0 if is_collection else stat.st_size
        return (
            "<D:response><D:href>%s</D:href><D:propstat><D:prop>"
            "<D:resourcetype>%s</D:resourcetype>"
            "<D:getcontentlength>%d</D:getcontentlength>"
            "<D:getlastmodified>%s</D:getlastmodified>"
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
            "</D:response>"
            % (self.href(local, is_collection), kind, size, http_date(stat.st_mtime))
        )

    def quota_answer(self, local):
        href = self.href(local, os.path.isdir(local))
        if not CONFIG["quota"]:
            # The server holds no such property, per RFC 4918.
            return self.multistatus(
                "<D:response><D:href>%s</D:href><D:propstat><D:prop>"
                "<D:quota-available-bytes/><D:quota-used-bytes/>"
                "</D:prop><D:status>HTTP/1.1 404 Not Found</D:status>"
                "</D:propstat></D:response>" % href
            )
        used = 0
        for folder, _, names in os.walk(CONFIG["root"]):
            for name in names:
                used += os.path.getsize(os.path.join(folder, name))
        available = max(0, CONFIG["limit"] - used)
        return self.multistatus(
            "<D:response><D:href>%s</D:href><D:propstat><D:prop>"
            "<D:quota-available-bytes>%d</D:quota-available-bytes>"
            "<D:quota-used-bytes>%d</D:quota-used-bytes>"
            "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
            "</D:response>" % (href, available, used)
        )

    def log_message(self, form, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), form % args))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--user", default="alice")
    parser.add_argument("--password", default="s3cret")
    parser.add_argument("--quota", action="store_true")
    parser.add_argument(
        "--switch", default="",
        help="a file that makes the server answer 503 while it exists")
    parser.add_argument(
        "--limit", type=int, default=2 * 1024 * 1024 * 1024,
        help="the byte limit the space query reports")
    given = parser.parse_args()

    CONFIG.update(
        root=os.path.abspath(given.root),
        user=given.user,
        password=given.password,
        quota=given.quota,
        switch=given.switch,
        limit=given.limit,
    )
    os.makedirs(CONFIG["root"], exist_ok=True)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(given.cert, given.key)
    server = ThreadingHTTPServer(("0.0.0.0", given.port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("WebDAV on https://localhost:%d%s, root %s, quota %s"
          % (given.port, BASE, CONFIG["root"], "yes" if given.quota else "no"))
    server.serve_forever()


if __name__ == "__main__":
    main()
