# PJSIP / SIP trunk integration

`MaximaSipClient` (Kotlin) loads the pjsua2 bindings **reflectively**.
The app builds and runs without PJSIP binaries; SIP calls return
`PJSIP_NOT_INSTALLED` until the artifacts below are shipped.

## 1. Build the binaries

```bash
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/27.0.12077973"
./tools/build_pjsip.sh              # pinned pjproject 2.15.1
```

Artifacts land in `third_party/pjsip/`:

- `lib/<abi>/libpjsua2.so` — native stack per ABI
- `java/org/pjsip/pjsua2/**` — Java bindings (requires SWIG)

## 2. Ship them in the APK

```
android/app/src/main/jniLibs/<abi>/libpjsua2.so   (from third_party/pjsip/lib)
```

Package the generated `org.pjsip.pjsua2` Java sources as an Android
library module and add `implementation project(":pjsua2")` to
`android/app/build.gradle`.

To link the C++ core against PJSIP as well, pass
`-DMAXIMA_WITH_PJSIP=ON` (see `src/CMakeLists.txt`).

## 3. Register against the trunk

```dart
final sip = SipClient();
await sip.register(
  server: 'sip.example-trunk.com',
  username: 'maxima-user',
  password: '<secret>',
  callerId: '+15551234567',   // pushed as P-Preferred-Identity /
                            // Remote-Party-ID for SIM caller-ID passthrough
  transport: 'tls',
  port: 5061,
);
await sip.call('sip:destination@trunk');
await sip.hangup();
```

The trunk must honor `P-Preferred-Identity`/`Remote-Party-ID` — most
SBCs (Asterisk `send_pai`, Kamailio `uac`/`rr`, Twilio Elastic SIP
Trunking) can be configured to trust these headers from authenticated
registrations and translate them into the outbound caller ID.

## 4. Telecom layer

`MaximaConnectionService` exposes calls to the OS as self-managed
connections (see `MANAGE_OWN_CALLS` in the manifest), keeping audio
packets unthrottled in the background.
