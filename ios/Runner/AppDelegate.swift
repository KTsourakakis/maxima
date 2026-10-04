import AVFoundation
import Flutter
import UIKit

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
