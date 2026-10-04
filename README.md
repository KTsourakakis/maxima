# Aura Straton Maxima AI — Maxima Master Key Core

A Flutter/Android application combining a hardened C++23 native core, a
foreground microphone pipeline, offline wake-word/STT recognition,
encrypted voice capture, RBAC-gated capabilities, remote Qwen inference,
SIP trunk telephony, and remote USB modem control.

## Project layout

```
lib/                    Dart application layer
  main.dart             Pulsing-core dashboard, FORCE_BLACK state
  services/             FFI bridge, RAG index, RBAC, gateways,
                        secure recorder, SIP client, wake-word dispatch
src/                    C++23 native core (CMake -> libnative_core.so)
android/                Android app (Kotlin, Gradle, manifest)
tools/
  chan_dongle_server.py Remote-host serial bridge for USB GSM modems
  build_pjsip.sh        PJSIP/pjsua2 Android cross-compile pipeline
  update_robot.sh       Staged, approval-gated tool updater
docs/                   Setup guides (accessibility, PJSIP, remote host)
test/                   flutter_test unit suite
init_setup.sh           Host bootstrapper (Flutter, CMake, Ollama)
```

## Build

```powershell
# 1. Toolchain (workspace-local, see C:\dev\toolchain\env.ps1)
. C:\dev\toolchain\env.ps1

# 2. Dependencies + tests + debug APK
flutter pub get
flutter test
flutter build apk --debug
```

The Gradle wrapper, Android SDK (platform 34/36, build-tools 34,
CMake 3.22.1, NDK 27.0.12077973), JDK 17 and Gradle 8.14.3 all live
under the workspace toolchain directory — nothing needs to be
installed globally.

## Platform support

The same Dart codebase runs on every target. Platform-specific
hardware surfaces are implemented per-OS:

| Platform      | Status        | Implementation path                                       |
|---------------|---------------|-----------------------------------------------------------|
| Android       | **Full**      | Kotlin foreground service, AudioRecord+Vosk, Keystore RSA wrap, Telecom ConnectionService, accessibility keys, battery gateway |
| iOS           | **Parity**    | `record` mic → libvosk FFI (statically linked), Keychain RSA wrap, AVSpeechSynthesizer TTS, battery monitor. Emergency SMS/call via `sms:`/`tel:` URLs (Apple always requires user confirmation). No accessibility-service / ConnectionService equivalent exists on iOS — `executeGlobalAction` reports unsupported |
| Windows       | **Parity**    | `native_core.dll` (MinGW/MSVC), `record` mic → libvosk FFI, `flutter_secure_storage` (DPAPI) key wrap, `maxima_sip_*` FFI bridge |
| macOS         | **Parity**    | `libnative_core.dylib`, `record` mic → libvosk FFI, `flutter_secure_storage` (Keychain) key wrap, `maxima_sip_*` FFI bridge |
| Linux         | **Parity**    | `libnative_core.so`, `record` mic → libvosk FFI, `flutter_secure_storage` (libsecret) key wrap, `maxima_sip_*` FFI bridge |

Build prerequisites per host:

- **Android**: the workspace toolchain (`C:\dev\toolchain\env.ps1`).
- **Windows**: MSVC Build Tools or MinGW GCC — `tools/build_native_desktop.ps1`
  compiles `native_core.dll` (verified with WinLibs GCC 15.3.0).
- **Linux**: `clang`/`gcc` + GTK dev packages — `tools/build_native_desktop.sh`.
- **macOS**: Xcode — `tools/build_native_desktop.sh`.
- **iOS**: macOS + Xcode + CocoaPods — `cd ios && pod install` builds the
  `native_core` pod and ZIPFoundation. See `docs/IOS_SETUP.md`.

Runtime configuration via `--dart-define`:

| Variable                | Purpose                                   |
|-------------------------|-------------------------------------------|
| `OLLAMA_BASE_URL`       | Remote Qwen/Ollama host (LAN only for http) |
| `REMOTE_HOST_BASE_URL`  | `chan_dongle_server.py` endpoint          |
| `REMOTE_HOST_TOKEN`     | Shared secret for the serial bridge       |
| `ALLOW_INSECURE_REMOTE` | `true` to permit non-LAN cleartext        |
| `VOSK_MODEL_PATH`       | Desktop/iOS Vosk model directory override |

Environment variables on desktop hosts:

| Variable            | Purpose                                        |
|---------------------|------------------------------------------------|
| `MAXIMA_NATIVE_LIB` | Absolute path override for the native core lib |
| `MAXIMA_VOSK_LIB`   | Absolute path override for libvosk             |
| `MAXIMA_VOSK_MODEL` | Vosk model directory override                  |

---

## 1. Vosk model — first-run download and configuration

The app ships the Vosk **engine** (`libvosk.so`) but not a model —
acoustic models are fetched once on the device.

### What happens under the hood

- `MaximaAudioPipeline` looks for a model directory at
  `<filesDir>/models/vosk-model`.
- If missing, it emits a `{"status": "model-missing"}` event on the
  `aura.straton.maxima/wake_word` EventChannel and keeps running —
  recording and voice-print capture still work, recognition is inert.
- `downloadVoskModel` (method channel) streams a model zip over HTTPS,
  unzips it with `MaximaModelManager`, flattens the archive root into
  `models/vosk-model`, and the next pipeline start picks it up.

### Downloading a model

From Dart (or let the UI trigger it):

```dart
const channel = MethodChannel('aura.straton.maxima/accessibility');
final path = await channel.invokeMethod<String>(
    'downloadVoskModel',
    {'url': 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip'},
);
```

Omit `url` to use the built-in default
(`vosk-model-small-en-us-0.15`, ~40 MB, Apache-2.0).

Recommended small models (download once over Wi-Fi):

| Model                              | Size | Notes                |
|------------------------------------|------|----------------------|
| `vosk-model-small-en-us-0.15`      | ~40 MB | English, default   |
| `vosk-model-small-el`              | ~50 MB | Greek              |
| `vosk-model-small-de-0.15`         | ~45 MB | German             |

Check status any time:

```dart
final status = await channel.invokeMethod<String>('voskModelStatus');
// "ready:<path>" or "missing:<path>"
```

### Wake phrases

`startWakeWordEngine` accepts an optional `{"phrases": {...}}` map of
*recognized text* → *action key* (`distress`, `purge`, `log`, `record`).
Defaults live in `MaximaAudioPipeline.DEFAULT_PHRASES`. Events arrive on
the EventChannel as `{"phrase": key, "transcript": ..., "final": bool}`
and are dispatched by `WakeWordController`.

---

## 2. Python server — chan_dongle USB control

The remote host that owns the USB GSM modem runs
`tools/chan_dongle_server.py` (stdlib HTTP + optional pyserial). It
exposes the `POST /api/serial-command` contract used by
`RemoteHostGateway`.

### Setup

```bash
pip install pyserial                 # only needed for real serial I/O

export MAXIMA_HOST_TOKEN=$(openssl rand -hex 24)   # shared secret
export MAXIMA_SERIAL_TTYS="/dev/ttyUSB*,/dev/ttyACM*"  # TTY allow-list
export MAXIMA_HOST_PORT=8080

python3 tools/chan_dongle_server.py
```

| Env var                | Default                          | Purpose              |
|------------------------|----------------------------------|----------------------|
| `MAXIMA_HOST_PORT`     | `8080`                           | Listen port          |
| `MAXIMA_HOST_BIND`     | `0.0.0.0`                        | Bind address         |
| `MAXIMA_HOST_TOKEN`    | *(unset = unauthenticated)*      | Shared secret        |
| `MAXIMA_SERIAL_TTYS`   | `/dev/ttyUSB*,/dev/ttyACM*,COM*` | TTY allow-list        |
| `MAXIMA_SERIAL_DRY_RUN`| auto (when pyserial missing)     | Echo, don't touch TTY|
| `MAXIMA_SERIAL_BAUD`   | `115200`                         | Baud rate            |

Windows host: set the same variables (`$env:MAXIMA_HOST_TOKEN = ...`)
and allow `COM*` TTYs.

### Verify

```bash
curl http://<host-ip>:8080/api/health
curl -X POST http://<host-ip>:8080/api/serial-command \
     -H "X-Maxima-Token: $MAXIMA_HOST_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"tty":"/dev/ttyUSB0","command":"AT+CSQ"}'
```

Dry-run mode (`MAXIMA_SERIAL_DRY_RUN=1`) echoes commands without
touching hardware — ideal for the first connectivity check.

App side:

```bash
flutter run \
  --dart-define=REMOTE_HOST_BASE_URL=http://<host-ip>:8080 \
  --dart-define=REMOTE_HOST_TOKEN=<same-secret>
```

Only whitelisted AT/chan_dongle commands reach the serial port; TTYs not
matching the allow-list are refused before opening the device. Full
contract details: `docs/REMOTE_HOST.md`.

---

## 3. Accessibility Service — manual enablement

`MaximaAccessibilityService` provides volume-button long-press mute and
`executeGlobalAction`. Android **requires the user to enable it in
system settings** — apps cannot self-grant accessibility access.

### Steps

1. Install the APK and launch Maxima; grant the runtime permissions on
   first start.
2. Open accessibility settings — either call
   `openAccessibilitySettings` from the app (method channel) or
   navigate manually:
   **Settings → Accessibility → Installed services**
   (Samsung: **Settings → Accessibility → Interaction and dexterity →
   Installed services**).
3. Tap **Maxima Accessibility Service**.
4. Toggle it **On** and confirm the system warning dialog.
   (The service only observes `KEYCODE_VOLUME_UP/DOWN` events and
   dispatches global actions — it does not read screen content.)
5. Return to the app and verify:

   ```dart
   final enabled = await MethodChannel('aura.straton.maxima/accessibility')
       .invokeMethod<bool>('isAccessibilityServiceEnabled');
   ```

### Resulting behavior

| Input                          | Result                                |
|--------------------------------|---------------------------------------|
| Volume key short press         | Normal system volume adjustment       |
| Volume key long press (>600ms) | Toggles compliant microphone mute     |
| `executeGlobalAction` channel  | Dispatches `GLOBAL_ACTION_*` to the OS|

While muted, the foreground mic stream stays up (persistent
notification, Android privacy indicator remains honest) and the audio
pipeline feeds silence to the recognizer and recorder. Full guide:
`docs/ACCESSIBILITY_SETUP.md`.

---

## Additional guides

- `docs/PJSIP_SETUP.md` — build pjsua2, register the SIP trunk,
  caller-ID passthrough via `P-Preferred-Identity` / `Remote-Party-ID`.
- `docs/REMOTE_HOST.md` — serial-bridge contract and environment
  variables.
- `docs/IOS_SETUP.md` — iOS pod install, libvosk linking, model
  setup, and platform constraints.
- `tools/build_native_desktop.{sh,ps1}` — compile `native_core` as a
  desktop shared library.
- `tools/build_pjsip.sh --host` — native pjsua build for the desktop
  SIP bridge.
- `init_setup.sh` — host bootstrapper (Flutter, CMake, Ollama +
  `qwen2.5:7b-instruct` readiness).
- `tools/update_robot.sh` — staged updates, gated by
  `MAXIMA_MASTER_APPROVAL=approved`.

## Security notes

- `.mxenc` recordings: chunked AES-256-GCM; the per-file data key is
  wrapped by a non-exportable platform key — Android Keystore
  RSA-2048, iOS Keychain RSA-2048, or the desktop OS secure store
  (DPAPI / Keychain / libsecret via `flutter_secure_storage`).
- Voice-ID is a spectral fingerprint **gate** (cosine match on band
  energies), not a forensic speaker model — treat failure as "needs a
  stronger check", never as proof of identity.
- Plain `http://` is only accepted for private/LAN hosts
  (`lib/services/lan_gate.dart`); public endpoints require `https://`
  or the explicit `ALLOW_INSECURE_REMOTE` override.
- Microphone mute is implemented via `AudioManager.isMicrophoneMute`;
  Android's privacy dot stays visible by design.
