import 'dart:io';

import 'package:flutter/services.dart';

import 'pjsip_ffi.dart';

/// Result of a SIP operation.
class SipResult {
    const SipResult({required this.ok, this.detail = ''});

    final bool ok;
    final String detail;
}

/// SIP trunk client with a unified API across platforms:
///
///  - Android: routed through the Kotlin `MaximaSipClient`, which
///    reflectively wraps PJSUA2 (`P-Preferred-Identity` /
///    `Remote-Party-ID` caller-ID passthrough).
///  - Windows / macOS / Linux: routed through the `maxima_sip_*` FFI
///    bridge over pjsua-lib (`PjsipFfi`), compiled into
///    `libnative_core` when built with `-DMAXIMA_WITH_PJSIP=ON`.
///
/// In both cases the stack degrades to `PJSIP_NOT_INSTALLED` results
/// when the PJSIP binaries from `tools/build_pjsip.sh` are absent.
class SipClient {
    SipClient({
        MethodChannel platform =
            const MethodChannel('aura.straton.maxima/accessibility'),
        PjsipFfi? desktop,
    })  : _platform = platform,
          _desktop = desktop ??
              (Platform.isAndroid ? null : PjsipFfi.tryCreate());

    final MethodChannel _platform;
    final PjsipFfi? _desktop;

    String? _domain;
    int _callId = -1;

    /// Registers against the SIP trunk.
    ///
    /// [callerId] is pushed as `P-Preferred-Identity` /
    /// `Remote-Party-ID` on Android, and as the From display name on
    /// desktop.
    Future<SipResult> register({
        required String server,
        required String username,
        required String password,
        String? callerId,
        String transport = 'tls',
        int port = 5061,
    }) async {
        final ffi = _desktop;
        if (ffi != null) {
            final transportId = transport == 'tls' ? 1 : 0;
            final init = ffi.init(transport: transportId, localPort: port);
            if (init == PjsipFfi.unavailable) {
                return const SipResult(
                    ok: false,
                    detail: 'PJSIP_NOT_INSTALLED',
                );
            }
            if (init < 0) {
                return const SipResult(ok: false, detail: 'SIP_INIT_FAILED');
            }
            final account = ffi.register(
                user: username,
                domain: server,
                password: password,
                callerId: callerId,
            );
            if (account < 0) {
                return const SipResult(
                    ok: false,
                    detail: 'SIP_REGISTER_FAILED',
                );
            }
            _domain = server;
            return SipResult(ok: true, detail: 'account=$account');
        }

        final args = <String, dynamic>{
            'server': server,
            'username': username,
            'password': password,
            'callerId': callerId,
            'transport': transport,
            'port': port,
        };
        return _invoke('sipRegister', args);
    }

    Future<SipResult> call(String destination) async {
        final ffi = _desktop;
        if (ffi != null) {
            final uri = destination.startsWith('sip:') ||
                    destination.startsWith('sips:')
                ? destination
                : 'sip:$destination@${_domain ?? ''}';
            final id = ffi.call(uri);
            if (id == PjsipFfi.unavailable) {
                return const SipResult(
                    ok: false,
                    detail: 'PJSIP_NOT_INSTALLED',
                );
            }
            if (id < 0) {
                return const SipResult(ok: false, detail: 'SIP_CALL_FAILED');
            }
            _callId = id;
            return SipResult(ok: true, detail: 'call=$id');
        }
        return _invoke('sipCall', {'destination': destination});
    }

    Future<SipResult> hangup() async {
        final ffi = _desktop;
        if (ffi != null) {
            if (_callId < 0) {
                return const SipResult(ok: true, detail: 'no active call');
            }
            final rc = ffi.hangup(_callId);
            _callId = -1;
            return SipResult(ok: rc >= 0, detail: 'rc=$rc');
        }
        return _invoke('sipHangup', const {});
    }

    Future<SipResult> _invoke(String method, Map<String, dynamic> args) async {
        try {
            final detail = await _platform.invokeMethod<String>(method, args);
            return SipResult(ok: true, detail: detail ?? '');
        } on PlatformException catch (error) {
            return SipResult(
                ok: false,
                detail: error.message ?? error.code,
            );
        } on MissingPluginException {
            return const SipResult(ok: false, detail: 'PJSIP_NOT_INSTALLED');
        }
    }
}
