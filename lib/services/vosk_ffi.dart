import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _ModelNewNative = Pointer Function(Pointer<Utf8>);
typedef _ModelFreeNative = Void Function(Pointer);
typedef _RecognizerNewNative = Pointer Function(Pointer, Float);
typedef _AcceptS16Native = Int32 Function(Pointer, Pointer<Int16>, Int32);
typedef _ResultNative = Pointer<Utf8> Function(Pointer);
typedef _RecognizerFreeNative = Void Function(Pointer);
typedef _SetLogLevelNative = Void Function(Int32);

/// Dart FFI binding over the libvosk C API (`vosk_api.h`).
///
/// The shared library is resolved in this order:
///  1. `MAXIMA_VOSK_LIB` environment variable (absolute path)
///  2. `libvosk.dll` / `vosk.dll`        (Windows, searched on PATH +
///     the executable directory)
///  3. `libvosk.so`                      (Linux, searched via ldconfig)
///  4. `libvosk.dylib`                   (macOS, DYLD paths)
///
/// On Android the Kotlin Vosk engine is used instead; this binding is
/// the desktop path.
class VoskFfi {
    VoskFfi._(DynamicLibrary library)
        : _setLogLevel = library
              .lookup<NativeFunction<_SetLogLevelNative>>(
                  'vosk_set_log_level',
              )
              .asFunction(),
          _modelNew = library
              .lookup<NativeFunction<_ModelNewNative>>('vosk_model_new')
              .asFunction(),
          _modelFree = library
              .lookup<NativeFunction<_ModelFreeNative>>('vosk_model_free')
              .asFunction(),
          _recognizerNew = library
              .lookup<NativeFunction<_RecognizerNewNative>>(
                  'vosk_recognizer_new',
              )
              .asFunction(),
          _acceptS16 = library
              .lookup<NativeFunction<_AcceptS16Native>>(
                  'vosk_recognizer_accept_waveform_s',
              )
              .asFunction(),
          _partialResult = library
              .lookup<NativeFunction<_ResultNative>>(
                  'vosk_recognizer_partial_result',
              )
              .asFunction(),
          _result = library
              .lookup<NativeFunction<_ResultNative>>(
                  'vosk_recognizer_result',
              )
              .asFunction(),
          _finalResult = library
              .lookup<NativeFunction<_ResultNative>>(
                  'vosk_recognizer_final_result',
              )
              .asFunction(),
          _recognizerFree = library
              .lookup<NativeFunction<_RecognizerFreeNative>>(
                  'vosk_recognizer_free',
              )
              .asFunction();

    final void Function(int) _setLogLevel;
    final Pointer Function(Pointer<Utf8>) _modelNew;
    final void Function(Pointer) _modelFree;
    final Pointer Function(Pointer, double) _recognizerNew;
    final int Function(Pointer, Pointer<Int16>, int) _acceptS16;
    final Pointer<Utf8> Function(Pointer) _partialResult;
    final Pointer<Utf8> Function(Pointer) _result;
    final Pointer<Utf8> Function(Pointer) _finalResult;
    final void Function(Pointer) _recognizerFree;

    /// Loads libvosk, or returns null when it is not installed.
    ///
    /// On iOS libvosk is expected to be statically linked into the
    /// binary (see docs/IOS_SETUP.md), so symbols are resolved from
    /// the process image.
    static VoskFfi? tryCreate() {
        if (Platform.isIOS) {
            try {
                return VoskFfi._(DynamicLibrary.process());
            } catch (_) {
                return null;
            }
        }
        final override = Platform.environment['MAXIMA_VOSK_LIB'];
        final candidates = <String>[
            if (override != null && override.isNotEmpty) override,
            if (Platform.isWindows) ...['libvosk.dll', 'vosk.dll'],
            if (Platform.isLinux) 'libvosk.so',
            if (Platform.isMacOS) ...['libvosk.dylib', 'libvosk.so'],
        ];
        for (final name in candidates) {
            try {
                return VoskFfi._(DynamicLibrary.open(name));
            } catch (_) {
                continue;
            }
        }
        return null;
    }

    void setLogLevel(int level) => _setLogLevel(level);

    /// Opens a model directory (e.g. `models/vosk-model-small-en-us-0.15`).
    VoskModelFfi? openModel(String modelPath) {
        final cPath = modelPath.toNativeUtf8();
        try {
            final handle = _modelNew(cPath);
            if (handle == nullptr) return null;
            return VoskModelFfi._(this, handle);
        } finally {
            malloc.free(cPath);
        }
    }
}

/// An opened Vosk model; create recognizers with [recognizer].
class VoskModelFfi {
    VoskModelFfi._(this._ffi, this._handle);

    final VoskFfi _ffi;
    final Pointer _handle;
    bool _closed = false;

    VoskRecognizerFfi? recognizer({double sampleRate = 16000}) {
        if (_closed) return null;
        final handle = _ffi._recognizerNew(_handle, sampleRate);
        if (handle == nullptr) return null;
        return VoskRecognizerFfi._(_ffi, handle);
    }

    void close() {
        if (_closed) return;
        _closed = true;
        _ffi._modelFree(_handle);
    }
}

/// Streaming recognizer accepting s16le PCM.
class VoskRecognizerFfi {
    VoskRecognizerFfi._(this._ffi, this._handle);

    final VoskFfi _ffi;
    final Pointer _handle;
    bool _closed = false;

    /// Feeds s16le samples. Returns true when an utterance boundary was
    /// reached and [result] holds the final hypothesis.
    bool acceptWaveform(List<int> pcmS16le) {
        if (_closed) return false;
        final buffer = malloc<Int16>(pcmS16le.length);
        try {
            buffer.asTypedList(pcmS16le.length).setAll(0, pcmS16le);
            return _ffi._acceptS16(_handle, buffer, pcmS16le.length) != 0;
        } finally {
            malloc.free(buffer);
        }
    }

    /// Partial hypothesis JSON: `{"partial": "..."}`.
    String partialResult() => _read(_ffi._partialResult);

    /// Final hypothesis JSON: `{"text": "...", "result": [...]}`.
    String result() => _read(_ffi._result);

    /// Non-resetting final hypothesis; call before [close].
    String finalResult() => _read(_ffi._finalResult);

    String _read(Pointer<Utf8> Function(Pointer) fn) {
        if (_closed) return '{}';
        final ptr = fn(_handle);
        if (ptr == nullptr) return '{}';
        return ptr.toDartString();
    }

    void close() {
        if (_closed) return;
        _closed = true;
        _ffi._recognizerFree(_handle);
    }
}
