import AVFoundation
import Flutter
import Security
import UIKit
import ZIPFoundation

/// iOS platform bridge for `aura.straton.maxima/accessibility`.
///
/// Implements the same MethodChannel contract as MainActivity.kt for
/// the features iOS supports natively:
///   - file storage path, mic permission, TTS (AVSpeechSynthesizer)
///   - Keychain DEK wrap/unwrap (MaximaKeyVault)
///   - Vosk model download/install status (MaximaModelManager)
///   - battery threshold monitoring -> `batteryLow` event to Dart
///   - emergency call/SMS via tel:/sms: (iOS always asks the user to
///     confirm; silent dispatch is not possible on this platform)
///
/// No iOS equivalents exist for Android's AccessibilityService and
/// Telecom ConnectionService — `executeGlobalAction` and
/// `isAccessibilityServiceEnabled` report unsupported. Wake-word/STT,
/// secure recording and SIP run on the Dart side (record + libvosk FFI
/// + maxima_sip_* symbols statically linked via the native_core pod).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private var channel: FlutterMethodChannel?
  private let synthesizer = AVSpeechSynthesizer()
  private var batteryThreshold: Float = 0
  private var batteryMonitor: Timer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let methodChannel = FlutterMethodChannel(
      name: "aura.straton.maxima/accessibility",
      binaryMessenger: messenger
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result) ?? result(FlutterMethodNotImplemented)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getAppFilesDir":
      result(documentsDirectory())

    case "getVoskModelDir":
      result(MaximaModelManager.shared.usableModelPath
             ?? MaximaModelManager.shared.modelDirectory.path)

    case "isVoskModelInstalled":
      result(MaximaModelManager.shared.isInstalled)

    case "downloadVoskModel":
      let args = call.arguments as? [String: Any]
      let url = args?["url"] as? String ?? MaximaModelManager.defaultModelUrl
      MaximaModelManager.shared.downloadModel(urlString: url) { outcome in
        switch outcome {
        case .success(let path):
          result(path)
        case .failure(let error):
          result(FlutterError(code: "MODEL_DOWNLOAD_FAILED",
                              message: error.localizedDescription,
                              details: nil))
        }
      }

    case "requestSystemPermissions":
      requestPermissions(result: result)

    case "startWakeWordEngine":
      // The Dart DesktopSttEngine (record + libvosk FFI) owns the
      // recognizer on iOS; nothing native to start.
      result(true)

    case "setMicrophoneMuted":
      // Mic gating is enforced by the Dart mic broker; kept as a
      // channel no-op so UI calls don't error.
      result(true)

    case "setBatteryThreshold":
      if let level = (call.arguments as? [String: Any])?["threshold"] as? NSNumber {
        batteryThreshold = level.floatValue / 100.0
        startBatteryMonitor()
      }
      result(true)

    case "speakText":
      if let text = (call.arguments as? [String: Any])?["text"] as? String {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        result(true)
      } else {
        result(false)
      }

    case "stopSpeech":
      synthesizer.stopSpeaking(at: .immediate)
      result(true)

    case "wrapDataKey":
      guard let args = call.arguments as? [String: Any],
            let b64 = args["key"] as? String,
            let dek = Data(base64Encoded: b64) else {
        result(FlutterError(code: "BAD_ARGS", message: "key missing", details: nil))
        return
      }
      do {
        result(try MaximaKeyVault.shared.wrap(data: dek).base64EncodedString())
      } catch {
        result(FlutterError(code: "KEYWRAP_FAILED",
                            message: error.localizedDescription, details: nil))
      }

    case "unwrapDataKey":
      guard let args = call.arguments as? [String: Any],
            let b64 = args["wrapped"] as? String,
            let blob = Data(base64Encoded: b64) else {
        result(FlutterError(code: "BAD_ARGS", message: "wrapped missing", details: nil))
        return
      }
      do {
        result(try MaximaKeyVault.shared.unwrap(data: blob).base64EncodedString())
      } catch {
        result(FlutterError(code: "KEYWRAP_FAILED",
                            message: error.localizedDescription, details: nil))
      }

    case "sendEmergencySms":
      // iOS cannot send SMS silently: sms: opens Messages with the
      // body prefilled and the user confirms.
      let args = call.arguments as? [String: Any]
      let number = args?["number"] as? String ?? ""
      let message = args?["message"] as? String ?? ""
      openUrl("sms:\(number)&body=\(message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
              result: result)

    case "startEmergencyCall":
      // tel: prompts the user to confirm the call.
      let number = (call.arguments as? [String: Any])?["number"] as? String ?? ""
      openUrl("tel:\(number)", result: result)

    case "openAccessibilitySettings":
      openUrl(UIApplication.openSettingsURLString, result: result)

    case "isAccessibilityServiceEnabled", "executeGlobalAction":
      // No AccessibilityService equivalent exists on iOS.
      result(false)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Helpers

  private func documentsDirectory() -> String {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
  }

  private func requestPermissions(result: @escaping FlutterResult) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
      }
    }
  }

  private func openUrl(_ string: String, result: @escaping FlutterResult) {
    guard let url = URL(string: string), UIApplication.shared.canOpenURL(url) else {
      result(false)
      return
    }
    UIApplication.shared.open(url) { ok in result(ok) }
  }

  /// Periodically enforces the battery threshold: below it (and not
  /// charging) we notify Dart via `batteryLow` so the speech engine
  /// can stop, matching the Android foreground-service behavior.
  private func startBatteryMonitor() {
    batteryMonitor?.invalidate()
    UIDevice.current.isBatteryMonitoringEnabled = true
    batteryMonitor = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
      [weak self] _ in
      guard let self = self else { return }
      let device = UIDevice.current
      let charging = device.batteryState == .charging || device.batteryState == .full
      if !charging, self.batteryThreshold > 0,
         device.batteryLevel >= 0, device.batteryLevel < self.batteryThreshold {
        self.channel?.invokeMethod("batteryLow", arguments: nil)
      }
    }
  }
}

// ============================================================================
// MaximaKeyVault — Keychain RSA-2048-OAEP wrap of the recording DEK.
// (Kept in this file so the class is compiled into the Runner target
// without requiring Xcode project file edits.)
// ============================================================================

/// iOS counterpart of the Android `MaximaKeyVault`.
///
/// Holds a non-extractable-by-tag RSA-2048 key pair in the iOS Keychain
/// and uses it to OAEP-wrap the AES-256 data-encryption keys embedded in
/// `.mxenc` container headers. The private key carries
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never
/// migrates off the device and is unavailable before first unlock.
final class MaximaKeyVault {
    static let shared = MaximaKeyVault()

    private let keyTag = "com.example.aura_straton_maxima_ai.recordingKey"

    private init() {}

    /// RSA-OAEP(SHA-256) encrypts [data] with the vault public key.
    /// Creates the pair on first use.
    func wrap(data: Data) throws -> Data {
        let publicKey = try publicKeyRef()
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as? Data else {
            throw error!.takeRetainedValue() as Error
        }
        return cipher
    }

    /// RSA-OAEP(SHA-256) decrypts a blob produced by [wrap].
    func unwrap(data: Data) throws -> Data {
        let privateKey = try privateKeyRef()
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as? Data else {
            throw error!.takeRetainedValue() as Error
        }
        return plain
    }

    /// true when the vault key pair exists (does not create it).
    func isProvisioned() -> Bool {
        return (try? privateKeyRef()) != nil
    }

    // MARK: - Keychain plumbing

    private func publicKeyRef() throws -> SecKey {
        let privateKey = try privateKeyRef()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw VaultError.missingPublicKey
        }
        return publicKey
    }

    private func privateKeyRef() throws -> SecKey {
        let tag = keyTag.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let item = item {
            return item as! SecKey
        }
        return try generatePair(tag: tag)
    }

    private func generatePair(tag: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return privateKey
    }

    enum VaultError: Error {
        case missingPublicKey
    }
}

// ============================================================================
// MaximaModelManager — Vosk model download + unzip (ZIPFoundation pod).
// ============================================================================

/// Downloads and unpacks a Vosk speech model into
/// `Application Support/models/vosk-model`.
///
/// Default model mirrors the Android manager:
/// `vosk-model-small-en-us-0.15` (~40 MB). The Dart side resolves the
/// directory through `getVoskModelDir`; bundling a model inside the
/// Runner.app resource bundle (`models/vosk-model`) is also detected
/// automatically.
final class MaximaModelManager {
    static let shared = MaximaModelManager()

    static let defaultModelUrl =
        "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

    private init() {}

    /// Directory where the extracted model lives.
    var modelDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("models/vosk-model", isDirectory: true)
    }

    /// A usable model exists either bundled in the app or extracted
    /// under Application Support.
    var isInstalled: Bool {
        if bundledModelUrl() != nil { return true }
        return FileManager.default.fileExists(atPath: modelDirectory.path)
    }

    /// Path Dart should open: bundled copy wins, then the downloaded one.
    var usableModelPath: String? {
        if let bundled = bundledModelUrl() { return bundled.path }
        return isInstalled ? modelDirectory.path : nil
    }

    private func bundledModelUrl() -> URL? {
        let candidates = [
            "vosk-model",
            "models/vosk-model",
            "vosk-model-small-en-us-0.15",
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Downloads [urlString] (default: the small English model) and
    /// unzips it so that `modelDirectory` contains the recognizer graph.
    func downloadModel(
        urlString: String = MaximaModelManager.defaultModelUrl,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(ModelError.badUrl))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tmp, _, error in
            do {
                guard let tmp = tmp else {
                    throw error ?? ModelError.downloadFailed
                }
                let fm = FileManager.default
                let target = self.modelDirectory
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }

                // The archive contains a single top-level directory
                // (e.g. vosk-model-small-en-us-0.15/); unzip into the
                // parent and rename it to `vosk-model`.
                let staging = target.deletingLastPathComponent()
                    .appendingPathComponent(".staging-\(UUID().uuidString)")
                try fm.createDirectory(
                    at: staging, withIntermediateDirectories: true
                )
                try fm.unzipItem(at: tmp, to: staging)
                defer { try? fm.removeItem(at: staging) }

                let entries = try fm.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                )
                guard let extracted = entries.first(where: {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey])
                        .isDirectory) == true
                }) else {
                    throw ModelError.badArchive
                }
                try fm.moveItem(at: extracted, to: target)
                completion(.success(target.path))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    enum ModelError: Error {
        case badUrl
        case downloadFailed
        case badArchive
    }
}
