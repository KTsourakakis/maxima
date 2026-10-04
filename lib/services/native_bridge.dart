import 'dart:ffi';
import 'dart:io';

class NativeTiming {
    const NativeTiming({
        required this.cycles,
        required this.frequency,
        required this.cacheZeroBlockSize,
    });

    final int cycles;
    final int frequency;
    final int cacheZeroBlockSize;

    double get nanoseconds {
        if (frequency <= 0) return 0;
        return cycles * 1000000000 / frequency;
    }
}

class NativeBridge {
    NativeBridge._(DynamicLibrary library)
        : _clearSecureMemoryCache = library
              .lookup<NativeFunction<Void Function()>>(
                  'clearSecureMemoryCache',
              )
              .asFunction(),
          _measureSecureWipeCycles = library
              .lookup<NativeFunction<Uint64 Function()>>(
                  'maxima_measure_secure_wipe_cycles',
              )
              .asFunction(),
          _counterNow = library
              .lookup<NativeFunction<Uint64 Function()>>(
                  'maxima_counter_now',
              )
              .asFunction(),
          _counterFrequency = library
              .lookup<NativeFunction<Uint64 Function()>>(
                  'maxima_counter_frequency',
              )
              .asFunction(),
          _cacheZeroBlockSize = library
              .lookup<NativeFunction<Uint64 Function()>>(
                  'maxima_cache_zero_block_size',
              )
              .asFunction(),
          _runtimeIntegrityOk = library
              .lookup<NativeFunction<Bool Function()>>(
                  'maxima_runtime_integrity_ok',
              )
              .asFunction(),
          _purgeIfCompromised = library
              .lookup<NativeFunction<Bool Function(Uint64, Uint64)>>(
                  'maxima_hardware_purge_if_compromised',
              )
              .asFunction(),
          _voipPipelineReady = library
              .lookup<NativeFunction<Bool Function()>>(
                  'maxima_voip_pipeline_ready',
              )
              .asFunction();

    final void Function() _clearSecureMemoryCache;
    final int Function() _measureSecureWipeCycles;
    final int Function() _counterNow;
    final int Function() _counterFrequency;
    final int Function() _cacheZeroBlockSize;
    final bool Function() _runtimeIntegrityOk;
    final bool Function(int, int) _purgeIfCompromised;
    final bool Function() _voipPipelineReady;

    static NativeBridge? tryCreate() {
        try {
            return NativeBridge._(openNativeLibrary());
        } catch (_) {
            return null;
        }
    }

    /// Opens the native core library. Exposed for sibling FFI bindings
    /// (e.g. [VoiceId]) that share `libnative_core`.
    static DynamicLibrary openNativeLibrary() => _openLibrary();

    static DynamicLibrary _openLibrary() {
        final override = Platform.environment['MAXIMA_NATIVE_LIB'];
        if (override != null && override.isNotEmpty) {
            return DynamicLibrary.open(override);
        }
        if (Platform.isAndroid || Platform.isLinux) {
            return DynamicLibrary.open('libnative_core.so');
        }
        if (Platform.isWindows) {
            return DynamicLibrary.open('native_core.dll');
        }
        if (Platform.isMacOS) {
            return DynamicLibrary.open('libnative_core.dylib');
        }
        if (Platform.isIOS) {
            return DynamicLibrary.process();
        }
        throw UnsupportedError('Unsupported platform for native_core');
    }

    int get counterNow => _counterNow();
    int get counterFrequency => _counterFrequency();
    int get cacheZeroBlockSize => _cacheZeroBlockSize();
    bool get runtimeIntegrityOk => _runtimeIntegrityOk();
    bool get voipPipelineReady => _voipPipelineReady();

    void clearSecureMemory() => _clearSecureMemoryCache();

    NativeTiming measureSecureWipe() {
        final cycles = _measureSecureWipeCycles();
        return NativeTiming(
            cycles: cycles,
            frequency: _counterFrequency(),
            cacheZeroBlockSize: _cacheZeroBlockSize(),
        );
    }

    bool purgeIfCompromised(int lastWipeCycles, int thresholdCycles) {
        return _purgeIfCompromised(lastWipeCycles, thresholdCycles);
    }
}
