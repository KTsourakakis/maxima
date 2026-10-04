import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

/// One-shot PCM capture into a file, consumed by `SecureRecorder`.
abstract class PcmCapture {
    /// Starts capturing. Returns false when capture cannot begin.
    Future<bool> start();

    /// Stops capturing. Returns a filesystem path to raw s16le
    /// 16 kHz mono PCM, or null when nothing was captured.
    Future<String?> stop();
}

/// Android implementation: the foreground service's AudioRecord
/// pipeline writes PCM into the app-private cache.
class AndroidPcmCapture extends PcmCapture {
    AndroidPcmCapture({
        MethodChannel platform =
            const MethodChannel('aura.straton.maxima/accessibility'),
    }) : _platform = platform;

    final MethodChannel _platform;

    @override
    Future<bool> start() async {
        try {
            return await _platform
                    .invokeMethod<bool>('startSecureRecording') ??
                false;
        } on PlatformException {
            return false;
        } on MissingPluginException {
            return false;
        }
    }

    @override
    Future<String?> stop() async {
        try {
            final path = await _platform
                .invokeMethod<String>('stopSecureRecording');
            return (path == null || path.isEmpty) ? null : path;
        } on PlatformException {
            return null;
        } on MissingPluginException {
            return null;
        }
    }
}

/// Desktop/iOS microphone broker backed by the `record` package
/// (WASAPI on Windows, AVFoundation on macOS/iOS, PulseAudio/ALSA on
/// Linux). Streams raw s16le PCM at 16 kHz mono — the same format the
/// Vosk recognizer and the `.mxenc` recorder consume.
///
/// The underlying stream is shared and broadcast so multiple consumers
/// (wake-word engine, secure recorder tee) can subscribe to the single
/// platform mic session.
class DesktopMicBroker {
    DesktopMicBroker({AudioRecorder? recorder}) : _injected = recorder;

    final AudioRecorder? _injected;
    AudioRecorder? _lazyRecorder;

    AudioRecorder get _recorder => _lazyRecorder ??= _injected ?? AudioRecorder();

    static const int sampleRate = 16000;

    Stream<Uint8List>? _shared;
    bool _streaming = false;

    /// When true, captured frames are dropped before reaching consumers
    /// — the desktop/iOS counterpart of the Android mute feed.
    bool muted = false;

    bool get isStreaming => _streaming;

    /// Checks and requests microphone permission on the host OS.
    Future<bool> ensurePermission() async {
        try {
            return await _recorder.hasPermission();
        } on MissingPluginException {
            return false;
        } on PlatformException {
            return false;
        }
    }

    /// Starts the microphone (once) and returns the shared broadcast
    /// PCM stream. Each chunk is little-endian s16 mono @16 kHz.
    Future<Stream<Uint8List>?> stream() async {
        final existing = _shared;
        if (existing != null) return existing;
        try {
            final raw = await _recorder.startStream(
                const RecordConfig(
                    encoder: AudioEncoder.pcm16bits,
                    sampleRate: sampleRate,
                    numChannels: 1,
                ),
            );
            _streaming = true;
            return _shared = raw.asBroadcastStream();
        } on MissingPluginException {
            return null;
        } on PlatformException {
            return null;
        }
    }

    /// Subscribes [onPcm] to the shared microphone stream.
    /// Returns false when the stream cannot start.
    Future<bool> pipe(void Function(Uint8List pcm) onPcm) async {
        final source = await stream();
        if (source == null) return false;
        source.listen(
            (pcm) {
                if (!muted) onPcm(pcm);
            },
            onError: (_) {},
        );
        return true;
    }

    Future<void> stop() async {
        _shared = null;
        if (_streaming) {
            _streaming = false;
            try {
                await _recorder.stop();
            } on MissingPluginException {
                // record plugin not present on this platform.
            } on PlatformException {
                // Host rejected stop; stream is already cancelled.
            }
        }
    }

    Future<void> dispose() async {
        await stop();
        try {
            await _lazyRecorder?.dispose();
        } on MissingPluginException {
            // record plugin not present on this platform.
        }
        _lazyRecorder = null;
    }
}

/// Buffers broker PCM into a file so `SecureRecorder` can seal it into
/// an `.mxenc` container — the desktop equivalent of the Android
/// pipeline's PCM sink.
class BrokerPcmCapture extends PcmCapture {
    BrokerPcmCapture({
        required DesktopMicBroker broker,
        String? directory,
    })  : _broker = broker,
          _directory = directory ?? Directory.systemTemp.path;

    final DesktopMicBroker _broker;
    final String _directory;

    IOSink? _sink;
    String? _path;
    int _bytesWritten = 0;

    @override
    Future<bool> start() async {
        await stop();
        final file = File(
            '$_directory/maxima_pcm_${DateTime.now().millisecondsSinceEpoch}.raw',
        );
        await file.parent.create(recursive: true);
        _sink = file.openWrite();
        _path = file.path;
        _bytesWritten = 0;
        return _broker.pipe((pcm) {
            _sink?.add(pcm);
            _bytesWritten += pcm.length;
        });
    }

    @override
    Future<String?> stop() async {
        final sink = _sink;
        _sink = null;
        final path = _path;
        _path = null;
        if (sink == null || path == null) return null;
        await sink.flush();
        await sink.close();
        return _bytesWritten > 0 ? path : null;
    }
}

/// Platform dispatch for `SecureRecorder`.
PcmCapture defaultPcmCapture({
    MethodChannel platform =
        const MethodChannel('aura.straton.maxima/accessibility'),
    DesktopMicBroker? broker,
    String? directory,
}) {
    if (Platform.isAndroid) {
        return AndroidPcmCapture(platform: platform);
    }
    return BrokerPcmCapture(
        broker: broker ?? DesktopMicBroker(),
        directory: directory,
    );
}
