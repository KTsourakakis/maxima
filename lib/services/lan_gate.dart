/// Gate that decides whether a remote endpoint URI may be used for
/// plaintext LAN communication.
///
/// Plain HTTP is only acceptable inside a private/loopback network
/// (RFC 1918 + link-local). Everything else must use HTTPS unless the
/// operator explicitly opts in with `--dart-define=ALLOW_INSECURE_REMOTE=true`.
library;

const bool _allowInsecureRemote =
    bool.fromEnvironment('ALLOW_INSECURE_REMOTE');

bool isPrivateLanHost(String host) {
    final lower = host.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (lower == 'localhost' || lower.endsWith('.localhost')) return true;
    if (lower.endsWith('.local') || lower.endsWith('.lan') ||
        lower.endsWith('.internal')) {
        return true;
    }

    final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(lower);
    if (v4 != null) {
        final octets = List.generate(
            4,
            (i) => int.parse(v4.group(i + 1)!),
        );
        if (octets.any((o) => o > 255)) return false;
        final a = octets[0];
        final b = octets[1];
        if (a == 10) return true; // 10.0.0.0/8
        if (a == 127) return true; // loopback
        if (a == 169 && b == 254) return true; // link-local
        if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
        if (a == 192 && b == 168) return true; // 192.168.0.0/16
        return false;
    }

    // IPv6 literals: fe80::/10 link-local, fc00::/7 ULA, ::1 loopback.
    final v6 = lower.replaceAll(RegExp(r'[\[\]]'), '');
    if (v6 == '::1') return true;
    if (v6.startsWith('fe80') || v6.startsWith('fe90') ||
        v6.startsWith('fea0') || v6.startsWith('feb0')) {
        return true;
    }
    if (v6.startsWith('fc') || v6.startsWith('fd')) return true;
    return false;
}

/// Returns true when [uri] may be contacted without TLS.
bool isAllowedInsecureEndpoint(Uri uri) {
    if (uri.scheme == 'https' || uri.scheme == 'wss') return true;
    if (uri.scheme != 'http' && uri.scheme != 'ws') return false;
    if (_allowInsecureRemote) return true;
    return isPrivateLanHost(uri.host);
}

/// Throws [StateError] when the endpoint violates the cleartext policy.
void assertEndpointAllowed(Uri uri) {
    if (!isAllowedInsecureEndpoint(uri)) {
        throw StateError(
            'Refusing plaintext connection to non-LAN host "${uri.host}". '
            'Use https:// or rebuild with '
            '--dart-define=ALLOW_INSECURE_REMOTE=true to override.',
        );
    }
}
