#!/usr/bin/env python3
"""
hicstream — Simple HTTP server with Range request and CORS support.

Serves local .hic files over HTTP so HiCStat can read headers via
Range requests from the browser. Expose via https://hicstream.3dg.io
using a reverse proxy (e.g., Caddy, nginx, Cloudflare Tunnel).

Usage:
    python hicstream.py -d /path/to/hic/files -p 8020

By default, only .hic files are served and directory listing is disabled.
To allow other file types:  --extensions .hic .cool .mcool
To enable directory listing: --allow-dirlist
"""
import os
import argparse
from http.server import HTTPServer, SimpleHTTPRequestHandler

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS, HEAD",
    "Access-Control-Allow-Headers": "Range",
    "Access-Control-Expose-Headers": "Content-Range, Content-Length, Accept-Ranges",
    "Access-Control-Max-Age": "86400",
}


class HicStreamHandler(SimpleHTTPRequestHandler):
    allow_dirlist = False
    allowed_extensions = {".hic"}

    def __init__(self, *args, directory=None, **kwargs):
        super().__init__(*args, directory=directory or os.getcwd(), **kwargs)

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(204)
        for k, v in CORS_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()

    def _check_extension(self, path):
        """Return True if file extension is in the allowed set."""
        if not self.allowed_extensions:
            return True
        _, ext = os.path.splitext(path)
        return ext.lower() in self.allowed_extensions

    def send_head(self):
        """Override to support Range requests and add CORS headers."""
        path = self.translate_path(self.path)

        if not os.path.exists(path):
            self.send_error(404, "File not found")
            return None

        if os.path.isdir(path):
            if not self.allow_dirlist:
                self.send_error(403, "Directory listing is disabled")
                return None
            return super().send_head()

        if not self._check_extension(path):
            self.send_error(403, "File type not allowed")
            return None

        file_size = os.path.getsize(path)
        start, end = 0, file_size - 1
        is_range = False

        if "Range" in self.headers:
            range_header = self.headers["Range"]
            if range_header.startswith("bytes="):
                parts = range_header[6:].split("-")
                start = int(parts[0]) if parts[0] else 0
                end = int(parts[1]) if parts[1] else file_size - 1
                if start >= file_size or end >= file_size or start > end:
                    self.send_error(416, "Requested Range Not Satisfiable")
                    return None
                is_range = True

        self.send_response(206 if is_range else 200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if is_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        for k, v in CORS_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()

        return open(path, "rb"), start, end

    def do_GET(self):
        """Handle GET with Range support."""
        result = self.send_head()
        if isinstance(result, tuple):
            file_obj, start, end = result
            try:
                file_obj.seek(start)
                self.wfile.write(file_obj.read(end - start + 1))
            finally:
                file_obj.close()
        elif result:
            try:
                self.copyfile(result, self.wfile)
            finally:
                result.close()

    def log_message(self, format, *args):
        """Prefix log with Range info when present."""
        range_info = ""
        if "Range" in self.headers:
            range_info = f" [{self.headers['Range']}]"
        super().log_message(format + range_info, *args)


def main():
    parser = argparse.ArgumentParser(
        description="Serve local .hic files with Range request and CORS support"
    )
    parser.add_argument("-p", "--port", type=int, default=8020,
                        help="Port to serve on (default: 8020)")
    parser.add_argument("-d", "--directory", type=str, default=os.getcwd(),
                        help="Directory to serve (default: current directory)")
    parser.add_argument("--allow-dirlist", action="store_true", default=False,
                        help="Enable directory listing (default: disabled)")
    parser.add_argument("--extensions", nargs="+", default=[".hic"],
                        metavar="EXT",
                        help="Allowed file extensions (default: .hic). "
                             "Use --extensions '*' to allow all files.")
    args = parser.parse_args()

    # Configure handler class attributes
    if args.extensions == ["*"]:
        HicStreamHandler.allowed_extensions = set()  # empty = allow all
    else:
        HicStreamHandler.allowed_extensions = {
            ext if ext.startswith(".") else f".{ext}"
            for ext in args.extensions
        }
    HicStreamHandler.allow_dirlist = args.allow_dirlist

    handler = lambda *a, **kw: HicStreamHandler(*a, directory=args.directory, **kw)
    httpd = HTTPServer(("0.0.0.0", args.port), handler)

    ext_display = "*" if not HicStreamHandler.allowed_extensions else \
        ", ".join(sorted(HicStreamHandler.allowed_extensions))

    print(f"hicstream — serving: {args.directory}")
    print(f"  Allowed extensions: {ext_display}")
    print(f"  Directory listing:  {'enabled' if args.allow_dirlist else 'disabled'}")
    print(f"  Local:   http://localhost:{args.port}")
    print(f"  Network: http://0.0.0.0:{args.port}")
    print(f"\nExpose via reverse proxy at https://hicstream.3dg.io")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
