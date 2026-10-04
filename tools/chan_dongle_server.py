#!/usr/bin/env python3
"""Maxima remote-host serial bridge (server side).

Implements the `serialCommandPath` contract consumed by
`lib/services/remote_host_gateway.dart`:

    POST /api/serial-command
    X-Maxima-Token: <shared secret>            (required when configured)
    {"tty": "/dev/ttyUSB0", "command": "AT+CSQ", "timeout_ms": 5000}

    200 {"ok": true, "tty": ..., "response": "...raw modem output..."}
    4xx/5xx {"ok": false, "error": "..."}

Intended for the host machine that physically owns the USB GSM dongle
(chan_dongle / AT-command capable serial TTY). Run it on the LAN host,
point the app at it with:

    flutter run \
        --dart-define=REMOTE_HOST_BASE_URL=http://<host-ip>:8080 \
        --dart-define=REMOTE_HOST_TOKEN=<shared-secret>

Environment:
    MAXIMA_HOST_PORT        listen port            (default 8080)
    MAXIMA_HOST_BIND        bind address           (default 0.0.0.0)
    MAXIMA_HOST_TOKEN       bearer token           (empty = open, not recommended)
    MAXIMA_SERIAL_TTYS      allowed TTYs, comma-sep (default /dev/ttyUSB*,COM*)
    MAXIMA_SERIAL_DRY_RUN   "1" = do not touch serial, echo commands
    MAXIMA_SERIAL_BAUD      baud rate              (default 115200)

Requires pyserial for real modem I/O (`pip install pyserial`).
Without it the server runs in dry-run mode and echoes commands.
"""

import json
import os
import re
import sys
from fnmatch import fnmatch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import serial  # type: ignore
    HAVE_SERIAL = True
except ImportError:  # pyserial not installed -> dry run only
    serial = None
    HAVE_SERIAL = False

PORT = int(os.environ.get("MAXIMA_HOST_PORT", "8080"))
BIND = os.environ.get("MAXIMA_HOST_BIND", "0.0.0.0")
TOKEN = os.environ.get("MAXIMA_HOST_TOKEN", "")
ALLOWED_TTYS = os.environ.get(
    "MAXIMA_SERIAL_TTYS", "/dev/ttyUSB*,/dev/ttyACM*,COM*"
).split(",")
BAUD = int(os.environ.get("MAXIMA_SERIAL_BAUD", "115200"))
DRY_RUN = os.environ.get("MAXIMA_SERIAL_DRY_RUN", "") == "1" or not HAVE_SERIAL

# Whitelist of AT/chan_dongle commands a remote client may issue.
# Anything else is rejected before it ever reaches the serial port.
ALLOWED_COMMANDS = re.compile(
    r"^("
    r"AT(\+CMD=?[0-9]*|\+CMGF=?[01]?|\+CMGS=.*|\+CMGR=\d+|\+CMGD=\d*|"
    r"\+CNMI=?[\d,]*|\+CSQ\??|\+COPS=?[\d,\"]*|\+CREG\??|\+CPIN\??|"
    r"\+CUSD=.*|\+CLCK=.*|\+CGMI\??|\+CGMM\??|\+CGSN\??|\+CIMI\??|"
    r"\+CNUM\??|D[\d;,*#+]+|H|A|O|E[01]?|V[01]?|Z)?|"
    r"DONGLE\s+(STATUS|CMD|RESET|STOP|START|USSD\s+.*|SMS\s+\+?\d+\s+.*)"
    r")$",
    re.IGNORECASE,
)

MAX_COMMAND = 128
MAX_RESPONSE = 1 << 20


def tty_allowed(tty: str) -> bool:
    return any(fnmatch(tty, pat.strip()) for pat in ALLOWED_TTYS)


def execute_command(tty: str, command: str, timeout_ms: int) -> dict:
    if not tty_allowed(tty):
        return {"ok": False, "error": f"tty '{tty}' is not in the allow-list"}
    if len(command) > MAX_COMMAND or not ALLOWED_COMMANDS.match(command.strip()):
        return {"ok": False, "error": "command rejected by policy"}
    if DRY_RUN:
        return {
            "ok": True,
            "tty": tty,
            "response": f"DRY-RUN: {command.strip()}\\r\\nOK",
            "dry_run": True,
        }

    ser = serial.Serial(tty, BAUD, timeout=max(timeout_ms, 500) / 1000.0)
    try:
        ser.write((command.strip() + "\r").encode("ascii", "replace"))
        chunks, total = [], 0
        while total < MAX_RESPONSE:
            data = ser.read(4096)
            if not data:
                break
            chunks.append(data)
            total += len(data)
            if b"\nOK" in data or b"\nERROR" in data:
                break
        return {
            "ok": True,
            "tty": tty,
            "response": b"".join(chunks).decode("ascii", "replace"),
        }
    finally:
        ser.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "MaximaRemoteHost/1.0"

    def _reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if self.path == "/api/health":
            self._reply(200, {
                "ok": True,
                "dry_run": DRY_RUN,
                "pyserial": HAVE_SERIAL,
            })
            return
        self._reply(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if TOKEN and self.headers.get("X-Maxima-Token") != TOKEN:
            self._reply(401, {"ok": False, "error": "unauthorized"})
            return
        if self.path != "/api/serial-command":
            self._reply(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 16384:
                raise ValueError("bad content length")
            payload = json.loads(self.rfile.read(length))
            tty = str(payload["tty"])
            command = str(payload["command"])
            timeout = int(payload.get("timeout_ms", 5000))
        except (ValueError, KeyError, json.JSONDecodeError) as error:
            self._reply(400, {"ok": False, "error": f"bad request: {error}"})
            return
        try:
            self._reply(200, execute_command(tty, command, timeout))
        except Exception as error:  # serial errors surface as 502
            self._reply(502, {"ok": False, "error": str(error)})

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[remote-host] " + fmt % args + "\n")


def main() -> None:
    mode = "DRY-RUN (pyserial unavailable or forced)" if DRY_RUN \
        else "serial-attached"
    print(f"[remote-host] listening on {BIND}:{PORT} — {mode}")
    print(f"[remote-host] allowed TTYs: {', '.join(ALLOWED_TTYS)}")
    if not TOKEN:
        print("[remote-host] WARNING: MAXIMA_HOST_TOKEN is not set; "
              "the API is unauthenticated on the LAN")
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
