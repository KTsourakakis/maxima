import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lan_gate.dart';

/// Client for the remote-host serial bridge
/// (`tools/chan_dongle_server.py`).
///
/// Contract: `POST {baseUri}{serialCommandPath}` with JSON body
/// `{"tty": "/dev/ttyUSB0", "command": "AT+CSQ", "timeout_ms": 5000}`
/// and header `X-Maxima-Token` when [authToken] is set.
/// The server replies `{"ok": true, "response": "...", "tty": ...}` or an
/// HTTP error code with `{"ok": false, "error": "..."}`.
class RemoteHostGateway {
    RemoteHostGateway({
        required this.baseUri,
        this.serialCommandPath = '/api/serial-command',
        this.authToken,
        http.Client? client,
    }) : _client = client ?? http.Client() {
        assertEndpointAllowed(baseUri);
    }

    static RemoteHostGateway? fromEnvironment() {
        const configuredBase =
            String.fromEnvironment('REMOTE_HOST_BASE_URL');
        if (configuredBase.isEmpty) return null;
        const configuredToken =
            String.fromEnvironment('REMOTE_HOST_TOKEN');
        try {
            return RemoteHostGateway(
                baseUri: Uri.parse(configuredBase),
                authToken:
                    configuredToken.isEmpty ? null : configuredToken,
            );
        } catch (_) {
            return null;
        }
    }

    final Uri baseUri;
    final String serialCommandPath;
    final String? authToken;
    final http.Client _client;

    Future<Map<String, dynamic>> sendSerialCommand({
        required String ttyDevice,
        required String command,
        Duration timeout = const Duration(seconds: 15),
    }) async {
        final response = await _client
            .post(
                baseUri.replace(path: serialCommandPath),
                headers: {
                    'Content-Type': 'application/json',
                    if (authToken != null)
                        'X-Maxima-Token': authToken!,
                },
                body: jsonEncode({
                    'tty': ttyDevice,
                    'command': command,
                    'timeout_ms': timeout.inMilliseconds,
                }),
            )
            .timeout(timeout + const Duration(seconds: 5));

        if (response.statusCode != 200) {
            String detail = 'HTTP ${response.statusCode}';
            try {
                final decoded = jsonDecode(response.body);
                if (decoded is Map && decoded['error'] != null) {
                    detail = '${decoded['error']}';
                }
            } catch (_) {}
            throw StateError('Remote host failed: $detail');
        }

        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        return {'ok': true, 'result': decoded};
    }

    void close() => _client.close();
}
