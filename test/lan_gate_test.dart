import 'package:aura_straton_maxima_ai/services/lan_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    group('isPrivateLanHost', () {
        test('accepts RFC1918 and loopback hosts', () {
            for (final host in [
                'localhost',
                '127.0.0.1',
                '10.0.0.5',
                '192.168.1.20',
                '172.16.3.4',
                '172.31.255.255',
                '169.254.10.10',
                'print-server.local',
                '::1',
            ]) {
                expect(isPrivateLanHost(host), isTrue, reason: host);
            }
        });

        test('rejects public and malformed hosts', () {
            for (final host in [
                '8.8.8.8',
                '203.0.113.7',
                '172.15.0.1',
                '172.32.0.1',
                'example.com',
                '999.1.1.1',
                '',
            ]) {
                expect(isPrivateLanHost(host), isFalse, reason: host);
            }
        });
    });

    group('isAllowedInsecureEndpoint', () {
        test('https is always allowed', () {
            expect(
                isAllowedInsecureEndpoint(
                    Uri.parse('https://api.example.com'),
                ),
                isTrue,
            );
        });
        test('http allowed only on LAN', () {
            expect(
                isAllowedInsecureEndpoint(
                    Uri.parse('http://192.168.1.50:11434'),
                ),
                isTrue,
            );
            expect(
                isAllowedInsecureEndpoint(
                    Uri.parse('http://203.0.113.9:11434'),
                ),
                isFalse,
            );
        });
        test('non-http(s) schemes rejected', () {
            expect(
                isAllowedInsecureEndpoint(Uri.parse('ftp://10.0.0.1')),
                isFalse,
            );
        });
    });

    test('assertEndpointAllowed throws for public http hosts', () {
        expect(
            () => assertEndpointAllowed(
                Uri.parse('http://203.0.113.9:11434'),
            ),
            throwsStateError,
        );
    });
}
