import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_bridge.dart';

/// FFI binding for the native spectral voice-print layer in
/// `src/native_core.cpp`.
///
/// The native side derives a compact spectral fingerprint (log band
/// energies + zero-crossing + RMS statistics) from 16 kHz mono float
/// PCM and matches against an enrolled template via cosine distance.
/// This is a lightweight biometric *gate*, not a forensic-grade
/// speaker model — treat verification failures as "fall back to a
/// stronger check", not as proof of identity.
class VoiceId {
    VoiceId._(DynamicLibrary library)
        : _enrollBegin = library
              .lookup<NativeFunction<Void Function()>>(
                  'maxima_voice_enroll_begin')
              .asFunction(),
          _enrollAdd = library
              .lookup<NativeFunction<Int32 Function(Pointer<Float>, Int32)>>(
                  'maxima_voice_enroll_add')
              .asFunction(),
          _enrollCommit = library
              .lookup<NativeFunction<Int32 Function()>>(
                  'maxima_voice_enroll_commit')
              .asFunction(),
          _verify = library
              .lookup<
                      NativeFunction<
                          Bool Function(Pointer<Float>, Int32, Float)>>(
                  'maxima_voice_verify')
              .asFunction(),
          _isEnrolled = library
              .lookup<NativeFunction<Bool Function()>>(
                  'maxima_voice_is_enrolled')
              .asFunction();

    final void Function() _enrollBegin;
    final int Function(Pointer<Float>, int) _enrollAdd;
    final int Function() _enrollCommit;
    final bool Function(Pointer<Float>, int, double) _verify;
    final bool Function() _isEnrolled;

    static VoiceId? tryCreate() {
        try {
            return VoiceId._(NativeBridge.openNativeLibrary());
        } catch (_) {
            return null;
        }
    }

    bool get isEnrolled => _isEnrolled();

    void beginEnrollment() => _enrollBegin();

    /// Adds one PCM capture to the enrollment set.
    /// Returns the number of accepted enrollment vectors so far, or
    /// a negative value when the buffer was rejected.
    int addEnrollmentSample(Float32List pcm) {
        return _withPcm(pcm, (ptr, n) => _enrollAdd(ptr, n));
    }

    /// Finalizes enrollment. Returns the template dimension on success.
    int commitEnrollment() => _enrollCommit();

    /// Verifies [pcm] against the enrolled template.
    /// [threshold] is a cosine-similarity cutoff in (0, 1).
    bool verify(Float32List pcm, {double threshold = 0.85}) {
        return _withPcm(pcm, (ptr, n) => _verify(ptr, n, threshold));
    }

    T _withPcm<T>(Float32List pcm, T Function(Pointer<Float>, int) fn) {
        final ptr = calloc<Float>(pcm.length);
        try {
            ptr.asTypedList(pcm.length).setAll(0, pcm);
            return fn(ptr, pcm.length);
        } finally {
            calloc.free(ptr);
        }
    }
}
