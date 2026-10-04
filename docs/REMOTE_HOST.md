# Remote host & USB chan_dongle contract

The phone-side `RemoteHostGateway` talks to a server component running
on the LAN host that owns the USB GSM dongle. The reference server is
`tools/chan_dongle_server.py` — a stdlib HTTP service with an AT-command
whitelist, per-TTY allow-listing, and token auth.

## HTTP contract

```
POST {REMOTE_HOST_BASE_URL}/api/serial-command
X-Maxima-Token: <MAXIMA_HOST_TOKEN>        (required when configured)
Content-Type: application/json

{"tty": "/dev/ttyUSB0", "command": "AT+CSQ", "timeout_ms": 5000}
```

Responses:

- `200 {"ok": true, "tty": ..., "response": "...modem output..."}`
- `200 {"ok": false, "error": "command rejected by policy"}` — whitelist miss
- `400/401/404/502 {"ok": false, "error": "..."}`
- `GET /api/health` → `{"ok": true, "dry_run": ..., "pyserial": ...}`

## Running the server

```bash
pip install pyserial            # real serial I/O (omit for dry-run)
export MAXIMA_HOST_TOKEN=$(openssl rand -hex 24)
export MAXIMA_SERIAL_TTYS="/dev/ttyUSB*,/dev/ttyACM*"
python3 tools/chan_dongle_server.py
```

| Env var               | Default                        | Purpose                  |
|-----------------------|--------------------------------|--------------------------|
| `MAXIMA_HOST_PORT`    | `8080`                         | Listen port              |
| `MAXIMA_HOST_BIND`    | `0.0.0.0`                      | Bind address             |
| `MAXIMA_HOST_TOKEN`   | *(empty = unauthenticated)*    | Shared secret            |
| `MAXIMA_SERIAL_TTYS`  | `/dev/ttyUSB*,/dev/ttyACM*,COM*`| TTY allow-list           |
| `MAXIMA_SERIAL_DRY_RUN`| auto when pyserial missing    | Echo commands, no serial |
| `MAXIMA_SERIAL_BAUD`  | `115200`                       | Serial baud              |

## App side

```bash
flutter run \
  --dart-define=REMOTE_HOST_BASE_URL=http://192.168.1.50:8080 \
  --dart-define=REMOTE_HOST_TOKEN=<same-secret>
```

`sendSerialCommand(ttyDevice: '/dev/ttyUSB0', command: 'AT+CSQ')`
returns the decoded response map. Commands not matching the AT/chan_dongle
whitelist are refused before they touch the serial port.

## Cleartext gate

Plain `http://` endpoints are only accepted for private/LAN hosts
(RFC 1918, link-local, `.local`, loopback). Public IPs require `https://`
or an explicit `--dart-define=ALLOW_INSECURE_REMOTE=true` override.
The same gate protects `OLLAMA_BASE_URL`.
