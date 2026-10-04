import 'package:aura_straton_maxima_ai/services/wake_on_lan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    const wol = WakeOnLan(broadcastAddress: '127.0.0.1', port: 40000);

    test('rejects malformed MAC addresses', () async {
        await expectLater(
            wol.send('not-a-mac'),
            throwsArgumentError,
        );
        await expectLater(
            wol.send('AA:BB:CC'),
            throwsArgumentError,
        );
    });

    test('sends a magic packet for valid MACs', () async {
        await wol.send('AA:BB:CC:DD:EE:FF');
        await wol.send('aabbccddeeff');
        await wol.send('AA-BB-CC-DD-EE-FF');
    });
}
