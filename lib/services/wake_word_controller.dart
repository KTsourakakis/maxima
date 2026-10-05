import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'access_control.dart';
import 'cognitive_search.dart';
import 'native_bridge.dart';
import 'secure_recorder.dart';
import 'sip_client.dart';

enum WakeWordAction {
    distressPanic,
    hardwarePurge,
    businessLog,
    secureRecording,
}

/// Maps recognized wake phrases to the four-tier action contract.
/// The Vosk engine on the Kotlin side emits normalized phrase keys
/// over the `aura.straton.maxima/wake_word` EventChannel.
class WakeWordController {
    WakeWordController({
        required AccessControl accessControl,
        NativeBridge? nativeBridge,
        CognitiveSearch? search,
        SecureRecorder? recorder,
        SipClient? sipClient,
        String? recordingsDirectory,
        MethodChannel platform =
            const MethodChannel('aura.straton.maxima/accessibility'),
        Stream<dynamic>? nativeEvents,
        this.onTranscript,
        this.onPartial,
        this.onStatus,
    })  : _accessControl = accessControl,
          _nativeBridge = nativeBridge,
          _search = search,
          _recorder = recorder,
          _sipClient = sipClient,
          _recordingsDirectory = recordingsDirectory,
          _platform = platform {
        if (nativeEvents != null) {
            attach(nativeEvents);
        }
    }

    /// Standard phrase map; the native engine reports one of these
    /// keys (`distress`, `purge`, `log`, `record`).
    static const Map<String, WakeWordAction> defaultPhraseMap = {
        'distress': WakeWordAction.distressPanic,
        'purge': WakeWordAction.hardwarePurge,
        'log': WakeWordAction.businessLog,
        'record': WakeWordAction.secureRecording,
    };

    final AccessControl _accessControl;
    final NativeBridge? _nativeBridge;
    final CognitiveSearch? _search;
    final SecureRecorder? _recorder;
    final SipClient? _sipClient;
    String? _recordingsDirectory;
    final MethodChannel _platform;

    /// Invoked for final transcripts that matched no command phrase —
    /// the agent loop uses them as LLM queries. [audio] is the PCM16
    /// ring-buffer snapshot captured alongside the utterance, used by
    /// the voice-identification gate.
    final void Function(String transcript, Uint8List? audio)?
        onTranscript;

    /// Invoked for in-progress (partial) transcripts that matched no
    /// command phrase — the UI uses them as live "hearing" feedback.
    final void Function(String transcript)? onPartial;

    /// Invoked for engine status events (`model-missing`, `mic-error`...).
    final void Function(String status, String? detail)? onStatus;

    /// Directory where sealed `.mxenc` recordings are written.
    /// Populated asynchronously from the platform `files` directory.
    set recordingsDirectory(String? value) => _recordingsDirectory = value;

    StreamSubscription<dynamic>? _eventSubscription;
    bool _recordingActive = false;

    /// Subscribes to the Kotlin wake-word event stream. Events are
    /// maps: `{"phrase": "distress", "transcript": "...", "confidence": 0.9}`.
    void attach(Stream<dynamic> nativeEvents) {
        _eventSubscription?.cancel();
        _eventSubscription = nativeEvents.listen((event) {
            if (event is! Map) return;
            final status = event['status'] as String?;
            if (status != null) {
                onStatus?.call(
                    status,
                    (event['detail'] ?? event['path']) as String?,
                );
                return;
            }
            final phrase = event['phrase'] as String?;
            final transcript = event['transcript'] as String?;
            if (phrase == null || phrase.isEmpty) {
                if (transcript == null || transcript.isEmpty) return;
                if (event['final'] == true) {
                    onTranscript?.call(
                        transcript,
                        event['audio'] as Uint8List?,
                    );
                } else {
                    onPartial?.call(transcript);
                }
                return;
            }
            final action = defaultPhraseMap[phrase.toLowerCase()];
            if (action == null) return;
            unawaited(handle(action, transcript: transcript));
        });
    }

    Future<void> dispose() => _eventSubscription?.cancel() ?? Future.value();

    bool get recordingActive => _recordingActive;

    Future<bool> handle(
        WakeWordAction action, {
        String? transcript,
        String? emergencyNumber,
        String? emergencyMessage,
    }) async {
        return switch (action) {
            WakeWordAction.distressPanic => _distressPanic(
                emergencyNumber: emergencyNumber,
                emergencyMessage: emergencyMessage,
            ),
            WakeWordAction.hardwarePurge => _hardwarePurge(),
            WakeWordAction.businessLog => _businessLog(transcript),
            WakeWordAction.secureRecording => _secureRecording(),
        };
    }

    Future<bool> _distressPanic({
        String? emergencyNumber,
        String? emergencyMessage,
    }) async {
        if (!_accessControl.allows(SecureCapability.voipPipeline) ||
            emergencyNumber == null ||
            emergencyNumber.isEmpty) {
            return false;
        }

        var sentSms = true;
        if (emergencyMessage != null && emergencyMessage.isNotEmpty) {
            sentSms = await _tryChannel<bool>(
                    'sendEmergencySms',
                    {
                        'number': emergencyNumber,
                        'message': emergencyMessage,
                    },
                ) ??
                false;
        }

        // Prefer the SIP trunk when the PJSIP bridge is installed;
        // otherwise fall back to the GSM dialer.
        var callStarted = false;
        final sip = _sipClient;
        if (sip != null) {
            callStarted = (await sip.call(emergencyNumber)).ok;
        }
        if (!callStarted) {
            callStarted = await _tryChannel<bool>(
                    'startEmergencyCall',
                    {'number': emergencyNumber},
                ) ??
                false;
        }
        return sentSms && callStarted;
    }

    /// Channel invocation that returns null when the host platform has
    /// no implementation (desktop runners, unit tests).
    Future<T?> _tryChannel<T>(String method, [Object? args]) async {
        try {
            return await _platform.invokeMethod<T>(method, args);
        } on PlatformException {
            return null;
        } on MissingPluginException {
            return null;
        }
    }

    Future<bool> _hardwarePurge() async {
        _nativeBridge?.clearSecureMemory();
        return true;
    }

    Future<bool> _businessLog(String? transcript) async {
        if (!_accessControl.allows(SecureCapability.businessLog) ||
            transcript == null ||
            transcript.trim().isEmpty ||
            _search == null) {
            return false;
        }
        await _search.ingestText(
            source: 'business-log',
            text: transcript,
        );
        return true;
    }

    /// Toggles encrypted capture: first trigger starts the native PCM
    /// recorder, second trigger seals the audio into an `.mxenc`
    /// AES-GCM container under [recordingsDirectory].
    Future<bool> _secureRecording() async {
        if (!_accessControl.allows(SecureCapability.secureRecording)) {
            return false;
        }
        final recorder = _recorder;
        if (recorder == null) return false;

        if (!_recordingActive) {
            _recordingActive = await recorder.start();
            return _recordingActive;
        }

        _recordingActive = false;
        final directory = _recordingsDirectory;
        if (directory == null) return false;
        final path =
            '$directory/recording_${DateTime.now().millisecondsSinceEpoch}.mxenc';
        return await recorder.stopAndSeal(destinationPath: path) > 0;
    }
}
