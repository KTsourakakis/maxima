# iOS Setup

The iOS runner lives in `ios/` and implements the
`aura.straton.maxima/accessibility` method channel in Swift
(`AppDelegate.swift`). Building requires macOS + Xcode + CocoaPods.

## Steps

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios   # or: open ios/Runner.xcworkspace in Xcode
```

`pod install` compiles the local `native_core` pod
(`ios/native_core.podspec` → `../src/native_core.cpp` +
`../src/sip_bridge.cpp`) and `ZIPFoundation` (model unzip). The pod is
linked with `-export_dynamic` so Dart FFI resolves `maxima_*` symbols
through `DynamicLibrary.process()`.

## What works on iOS

| Feature | iOS implementation |
|---|---|
| Mic capture | `record` plugin (AVAudioEngine), s16le 16 kHz mono |
| Wake-word / STT | `DesktopSttEngine` → libvosk C API via `DynamicLibrary.process()` |
| Encrypted recording | `SecureRecorder` → `BrokerPcmCapture` tee → AES-GCM `.mxenc` |
| Key wrap | iOS Keychain RSA-2048-OAEP (`MaximaKeyVault.swift`) — same channel contract as Android Keystore |
| Voice-ID | `native_core` FFI (compiled in via the pod) |
| TTS | `AVSpeechSynthesizer` (`speakText`/`stopSpeech`) |
| Battery gateway | `UIDevice` battery monitor → `batteryLow` channel event |
| SIP | `maxima_sip_*` FFI (build pjproject for iOS with `MAXIMA_WITH_PJSIP=ON`) |
| Emergency call/SMS | `tel:` / `sms:` URLs — iOS always asks the user to confirm |

## What iOS cannot do (platform constraints, not app bugs)

- **Accessibility service** — no equivalent API. Volume-button
  interception and `executeGlobalAction` return unsupported.
- **ConnectionService** — iOS VoIP goes through CallKit; a self-managed
  telecom connection is not available.
- **Silent SMS/call** — Apple requires user confirmation on both.
- **Always-on background mic** — `UIBackgroundModes: audio` (declared
  in Info.plist) permits capture only while an audio session is active
  and the app is foregrounded or legitimately recording.

## libvosk on iOS

`VoskFfi` resolves `vosk_*` symbols via `DynamicLibrary.process()`.
Link the Vosk iOS build (from `vosk-api`, `vosk-ios` example produces
`libvosk.xcframework`) into the Runner target — e.g. add the framework
in Xcode or extend the Podfile:

```ruby
pod 'vosk-api', :path => '../third_party/vosk-ios'   # local vosk build
```

## Vosk model on iOS

Two options:

1. **Bundle**: drag `vosk-model-small-en-us-0.15/` into the Xcode
   project as a **folder reference** under `models/vosk-model` —
   detected automatically.
2. **Download**: call `downloadVoskModel` once; the Swift
   `MaximaModelManager` unzips into Application Support and
   `getVoskModelDir` returns the path to the Dart engine.
