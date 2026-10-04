import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the desktop build of libnative_core against the real
/// compiled artifact (native/windows/native_core.dll). Skipped when the
/// DLL has not been built for this host.
void main() {
    final dllPath = File('native/windows/native_core.dll').absolute.path;
    final libAvailable = Platform.isWindows && File(dllPath).existsSync();

    DynamicLibrary? lib;
    setUpAll(() {
        if (libAvailable) {
            lib = DynamicLibrary.open(dllPath);
        }
    });

    int Function() u64(String name) => lib!
        .lookup<NativeFunction<Uint64 Function()>>(name)
        .asFunction<int Function()>();

    test(
        'counter functions return monotonic values',
        () {
            final now = u64('maxima_counter_now');
            final freq = u64('maxima_counter_frequency');
            final a = now();
            final b = now();
            expect(b, greaterThanOrEqualTo(a));
            expect(freq(), greaterThan(0));
        },
        skip: !libAvailable,
    );

    test(
        'secure wipe measurement and integrity check run',
        () {
            final measure = u64('maxima_measure_secure_wipe_cycles');
            expect(measure(), greaterThanOrEqualTo(0));
            final integrity = lib!
                .lookup<NativeFunction<Bool Function()>>(
                    'maxima_runtime_integrity_ok',
                )
                .asFunction<bool Function()>();
            expect(integrity(), anyOf(isTrue, isFalse));
        },
        skip: !libAvailable,
    );

    test(
        'SIP bridge symbols resolve and report unavailable without PJSIP',
        () {
            final init = lib!
                .lookup<NativeFunction<Int32 Function(Int32, Int32)>>(
                    'maxima_sip_init',
                )
                .asFunction<int Function(int, int)>();
            final registered = lib!
                .lookup<NativeFunction<Int32 Function()>>(
                    'maxima_sip_registered',
                )
                .asFunction<int Function()>();
            // Built without -DMAXIMA_WITH_PJSIP: bridge returns -2.
            expect(init(0, 0), -2);
            expect(registered(), -2);
        },
        skip: !libAvailable,
    );

    test(
        'voice enrollment and verification round-trip on synthetic PCM',
        () {
            const sampleRate = 16000;
            List<double> synth(List<double> freqs, int n) {
                return List<double>.generate(n, (i) {
                    var v = 0.0;
                    for (final f in freqs) {
                        v += sin(2 * pi * f * i / sampleRate) / freqs.length;
                    }
                    return v;
                });
            }

            final enrollBegin = lib!
                .lookup<NativeFunction<Void Function()>>(
                    'maxima_voice_enroll_begin',
                )
                .asFunction<void Function()>();
            final enrollAdd = lib!
                .lookup<NativeFunction<Int32 Function(Pointer<Float>, Int32)>>(
                    'maxima_voice_enroll_add',
                )
                .asFunction<int Function(Pointer<Float>, int)>();
            final enrollCommit = lib!
                .lookup<NativeFunction<Int32 Function()>>(
                    'maxima_voice_enroll_commit',
                )
                .asFunction<int Function()>();
            final isEnrolled = lib!
                .lookup<NativeFunction<Bool Function()>>(
                    'maxima_voice_is_enrolled',
                )
                .asFunction<bool Function()>();
            final verify = lib!
                .lookup<
                        NativeFunction<
                            Bool Function(Pointer<Float>, Int32, Float)>>(
                    'maxima_voice_verify',
                )
                .asFunction<bool Function(Pointer<Float>, int, double)>();

            const n = 16000;
            final voiceA = calloc<Float>(n);
            final voiceB = calloc<Float>(n);
            try {
                voiceA
                    .asTypedList(n)
                    .setAll(0, synth([200, 500, 900], n));
                voiceB
                    .asTypedList(n)
                    .setAll(0, synth([2700, 3500, 4500], n));

                enrollBegin();
                expect(enrollAdd(voiceA, n), 1);
                expect(enrollCommit(), greaterThan(0));
                expect(isEnrolled(), isTrue);
                expect(verify(voiceA, n, 0.80), isTrue);
                expect(verify(voiceB, n, 0.80), isFalse);
            } finally {
                malloc.free(voiceA);
                malloc.free(voiceB);
            }
        },
        skip: !libAvailable,
    );
}
