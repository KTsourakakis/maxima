import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_bridge.dart';

typedef _InitNative = Int32 Function(Int32, Int32);
typedef _RegisterNative = Int32 Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
);
typedef _CallNative = Int32 Function(Pointer<Utf8>);
typedef _HangupNative = Int32 Function(Int32);
typedef _NoArgNative = Int32 Function();

/// FFI client over the `maxima_sip_*` bridge compiled into
/// `libnative_core` (see `src/sip_bridge.cpp`). The bridge wraps
/// pjsua-lib when the library was built with `-DMAXIMA_WITH_PJSIP=ON`;
/// otherwise every call returns [unavailable] so callers degrade
/// cleanly instead of crashing.
///
/// This is the desktop SIP path — Android uses the Kotlin
/// `MaximaSipClient` reflection bridge over PJSUA2.
class PjsipFfi {
    PjsipFfi._(DynamicLibrary library)
        : _init = library
              .lookup<NativeFunction<_InitNative>>('maxima_sip_init')
              .asFunction(),
          _register = library
              .lookup<NativeFunction<_RegisterNative>>('maxima_sip_register')
              .asFunction(),
          _call = library
              .lookup<NativeFunction<_CallNative>>('maxima_sip_call')
              .asFunction(),
          _hangup = library
              .lookup<NativeFunction<_HangupNative>>('maxima_sip_hangup')
              .asFunction(),
          _registered = library
              .lookup<NativeFunction<_NoArgNative>>('maxima_sip_registered')
              .asFunction(),
          _shutdown = library
              .lookup<NativeFunction<_NoArgNative>>('maxima_sip_shutdown')
              .asFunction();

    static const int ok = 0;
    static const int error = -1;
    static const int unavailable = -2;
    static const int badArgs = -3;

    final int Function(int, int) _init;
    final int Function(
        Pointer<Utf8>,
        Pointer<Utf8>,
        Pointer<Utf8>,
        Pointer<Utf8>,
    ) _register;
    final int Function(Pointer<Utf8>) _call;
    final int Function(int) _hangup;
    final int Function() _registered;
    final int Function() _shutdown;

    /// Binds the bridge exports from `libnative_core`. Returns null
    /// when the library or symbols are absent.
    static PjsipFfi? tryCreate() {
        try {
            return PjsipFfi._(NativeBridge.openNativeLibrary());
        } catch (_) {
            return null;
        }
    }

    /// transport: `0` = UDP, `1` = TLS. localPort `0` = ephemeral.
    int init({required int transport, int localPort = 0}) =>
        _init(transport, localPort);

    /// Registers a digest-auth account; returns the account id (>=0)
    /// or a negative error code. [callerId] becomes the From display
    /// name on outbound calls.
    int register({
        required String user,
        required String domain,
        required String password,
        String? callerId,
    }) {
        final cUser = user.toNativeUtf8();
        final cDomain = domain.toNativeUtf8();
        final cPassword = password.toNativeUtf8();
        final cCallerId = (callerId ?? '').toNativeUtf8();
        try {
            return _register(cUser, cDomain, cPassword, cCallerId);
        } finally {
            malloc.free(cUser);
            malloc.free(cDomain);
            malloc.free(cPassword);
            malloc.free(cCallerId);
        }
    }

    /// Places an outbound call; returns the call id (>=0) or a
    /// negative error code.
    int call(String sipUri) {
        final cUri = sipUri.toNativeUtf8();
        try {
            return _call(cUri);
        } finally {
            malloc.free(cUri);
        }
    }

    int hangup(int callId) => _hangup(callId);

    /// 1 = registered (200), 0 = pending/failed, -2 = unavailable.
    int registrationState() => _registered();

    int shutdown() => _shutdown();
}
