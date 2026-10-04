import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'mic_broker.dart';
import 'vosk_ffi.dart';

/// Desktop wake-word / STT engine.
///
/// `record` (WASAPI / AVFoundation / PulseAudio) feeds s16le 16 kHz PCM
/// into a libvosk recognizer; hypotheses are matched against
/// [phraseAliases] and emitted as `{"phrase": key, "transcript": ...,
/// "confidence": 1.0}` — the same event contract the Kotlin
/// `MaximaAudioPipeline` produces on Android, so `WakeWordController`
/// is platform-agnostic.
class DesktopSttEngine {
    DesktopSttEngine._({
        required VoskModelFfi model,
        required DesktopMicBroker broker,
        Map<String, List<String>>? phraseAliases,
    })  : _model = model,
          _broker = broker,
          _aliases = phraseAliases ?? defaultAliases;

    /// Aliases mapping a wake-phrase key (the contract keys used by
    /// `WakeWordController.defaultPhraseMap`) to spoken variants.
    static const Map<String, List<String>> defaultAliases = {
        'distress': ['distress', 'emergency', 'help me', 'panic'],
        'purge': ['purge', 'wipe', 'blackout'],
        'log': ['log', 'business log', 'note'],
        'record': ['record', 'secure recording'],
    };

    final VoskModelFfi _model;
    final DesktopMicBroker _broker;
    final Map<String, List<String>> _aliases;

    final StreamController<Map<String, Object?>> _events =
        StreamController<Map<String, Object?>>.broadcast();

    VoskRecognizerFfi? _recognizer;
    StreamSubscription<Uint8List>? _micSub;
    bool _running = false;

    /// Events in the Android channel shape for `WakeWordController.attach`.
    Stream<Map<String, Object?>> get events => _events.stream;

    bool get isRunning => _running;

    /// Resolves the Vosk model directory:
    /// `VOSK_MODEL_PATH` dart-define > `MAXIMA_VOSK_MODEL` env >
    /// `<exe>/models/vosk-model` > `models/vosk-model` (cwd).
    ///
    /// On iOS, `<exe>/models/vosk-model` resolves inside the app bundle
    /// when the model is shipped as a folder reference; downloaded
    /// models are found through the `getVoskModelDir` channel via
    /// [tryCreateAsync].
    static String? resolveModelPath({String? explicit}) {
        if (explicit != null && explicit.isNotEmpty) {
            return Directory(explicit).existsSync() ? explicit : null;
        }
        const defined = String.fromEnvironment('VOSK_MODEL_PATH');
        if (defined.isNotEmpty && Directory(defined).existsSync()) {
            return defined;
        }
        final envPath = Platform.environment['MAXIMA_VOSK_MODEL'];
        if (envPath != null &&
            envPath.isNotEmpty &&
            Directory(envPath).existsSync()) {
            return envPath;
        }
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        for (final candidate in [
            '$exeDir/models/vosk-model',
            'models/vosk-model',
        ]) {
            if (Directory(candidate).existsSync()) return candidate;
        }
        return null;
    }

    /// Creates an engine when libvosk and a model are installed;
    /// returns null otherwise. [modelPath] overrides resolution.
    static DesktopSttEngine? tryCreate({
        String? modelPath,
        DesktopMicBroker? broker,
        Map<String, List<String>>? phraseAliases,
    }) {
        final vosk = VoskFfi.tryCreate();
        if (vosk == null) return null;
        final resolved = resolveModelPath(explicit: modelPath);
        if (resolved == null) return null;
        final model = vosk.openModel(resolved);
        if (model == null) return null;
        return DesktopSttEngine._(
            model: model,
            broker: broker ?? DesktopMicBroker(),
            phraseAliases: phraseAliases,
        );
    }

    /// Async variant for mobile: on iOS the model may live under
    /// Application Support (downloaded) or the app bundle (shipped),
    /// resolved by the native `getVoskModelDir` channel.
    static Future<DesktopSttEngine?> tryCreateAsync({
        String? modelPath,
        DesktopMicBroker? broker,
        Map<String, List<String>>? phraseAliases,
    }) async {
        var resolved = resolveModelPath(explicit: modelPath);
        if (resolved == null && (Platform.isIOS || Platform.isAndroid)) {
            try {
                const channel = MethodChannel(
                    'aura.straton.maxima/accessibility',
                );
                final dir = await channel.invokeMethod<String>(
                    'getVoskModelDir',
                );
                if (dir != null &&
                    dir.isNotEmpty &&
                    Directory(dir).existsSync()) {
                    resolved = dir;
                }
            } on MissingPluginException {
                // No native model directory provider.
            } on PlatformException {
                // Provider declined; continue without a model.
            }
        }
        if (resolved == null) return null;
        final vosk = VoskFfi.tryCreate();
        if (vosk == null) return null;
        final model = vosk.openModel(resolved);
        if (model == null) return null;
        return DesktopSttEngine._(
            model: model,
            broker: broker ?? DesktopMicBroker(),
            phraseAliases: phraseAliases,
        );
    }

    /// Starts microphone capture and recognition. Returns false when
    /// the mic permission/stream or the recognizer cannot start.
    Future<bool> start() async {
        if (_running) return true;
        if (!await _broker.ensurePermission()) return false;
        final source = await _broker.stream();
        if (source == null) return false;
        final recognizer = _model.recognizer();
        if (recognizer == null) return false;
        _recognizer = recognizer;
        _running = true;
        _micSub = source.listen(_consume, onError: (_) {});
        return true;
    }

    void _consume(Uint8List pcm) {
        final recognizer = _recognizer;
        if (recognizer == null || pcm.isEmpty) return;
        final samples = pcm.length >> 1;
        final s16 = Int16List.view(
            pcm.buffer,
            pcm.offsetInBytes,
            samples,
        );
        final utteranceDone = recognizer.acceptWaveform(s16);
        final json = utteranceDone
            ? recognizer.result()
            : recognizer.partialResult();
        final transcript = _extractText(json);
        if (transcript == null || transcript.isEmpty) return;
        final phrase = matchPhrase(transcript);
        if (phrase != null) {
            _events.add({
                'phrase': phrase,
                'transcript': transcript,
                'confidence': 1.0,
            });
        }
    }

    /// Extracts the transcript from a Vosk JSON hypothesis
    /// (`{"text": ...}` or `{"partial": ...}`).
    static String? _extractText(String json) {
        try {
            final decoded = jsonDecode(json);
            if (decoded is! Map) return null;
            final text = decoded['text'] ?? decoded['partial'];
            return text is String ? text.trim() : null;
        } on FormatException {
            return null;
        }
    }

    /// Maps a transcript to a wake-phrase key, or null.
    String? matchPhrase(String transcript) {
        final lower = transcript.toLowerCase();
        for (final entry in _aliases.entries) {
            for (final alias in entry.value) {
                if (lower.contains(alias)) return entry.key;
            }
        }
        return null;
    }

    Future<void> stop() async {
        _running = false;
        await _micSub?.cancel();
        _micSub = null;
        _recognizer?.finalResult();
        _recognizer?.close();
        _recognizer = null;
        await _broker.stop();
    }

    Future<void> dispose() async {
        await stop();
        _model.close();
        await _broker.dispose();
        await _events.close();
    }
}
