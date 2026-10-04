import 'dart:typed_data';

import 'package:aura_straton_maxima_ai/services/secure_recorder.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
    final codec = SecureRecorderCodec();

    Future<Uint8List> roundTrip(
        List<int> plaintext, {
        int wrappedLength = 256,
    }) async {
        final key = await codec.generateDataKey();
        final container = await codec.encryptBytes(
            plaintext,
            dataKey: key,
            wrappedKey: List<int>.filled(wrappedLength, 0xAB),
            baseNonce: Uint8List.fromList(
                List<int>.generate(
                    SecureRecorderCodec.nonceBytes,
                    (i) => i * 7 % 256,
                ),
            ),
        );
        return codec.decryptBytes(
            container,
            unwrap: (_) async => key,
        );
    }

    test('AES-GCM round-trip restores PCM bytes', () async {
        final pcm = List<int>.generate(64000, (i) => i % 256);
        final restored = await roundTrip(pcm);
        expect(restored, orderedEquals(pcm));
    });

    test('round-trip works across multiple chunks', () async {
        final big = List<int>.filled(
            SecureRecorderCodec.chunkBytes * 2 + 12345,
            0x5A,
        );
        final restored = await roundTrip(big);
        expect(restored.length, big.length);
    });

    test('empty payloads produce a valid container', () async {
        final restored = await roundTrip(<int>[]);
        expect(restored, isEmpty);
    });

    test('tampered ciphertext fails GCM verification', () async {
        final key = await codec.generateDataKey();
        final nonce = Uint8List(SecureRecorderCodec.nonceBytes);
        final container = await codec.encryptBytes(
            List<int>.filled(4096, 0x11),
            dataKey: key,
            wrappedKey: List<int>.filled(64, 1),
            baseNonce: nonce,
        );
        // Flip a bit inside the first ciphertext chunk.
        final offset = SecureRecorderCodec.magic.length + 1 +
            SecureRecorderCodec.nonceBytes + 2 + 64 + 4;
        container[offset] ^= 0xFF;
        await expectLater(
            codec.decryptBytes(container, unwrap: (_) async => key),
            throwsA(isA<SecretBoxAuthenticationError>()),
        );
    });

    test('bad magic is rejected', () async {
        final container = Uint8List.fromList(
            [0, 1, 2, 3, 4, 5, ...List.filled(32, 0)],
        );
        await expectLater(
            codec.decryptBytes(container, unwrap: (_) async => SecretKey([])),
            throwsFormatException,
        );
    });
}
