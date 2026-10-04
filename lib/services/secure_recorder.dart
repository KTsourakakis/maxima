import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'key_wrap.dart';
import 'mic_broker.dart';

/// Streaming AES-256-GCM container for microphone captures.
///
/// File layout (little-endian):
/// ```
/// "MXENC1"   6-byte magic
/// u8         version (1)
/// 12B        base nonce (chunk nonce = base[0..8] || counter u32be)
/// u16        wrapped DEK length
/// ...        wrapped DEK bytes (Android Keystore RSA-OAEP)
/// repeated   u32 ciphertextLen | ciphertext | 16B GCM tag
/// ```
/// Each chunk is independently authenticated so a truncated or
/// tampered stream fails verification without buffering the file.
class SecureRecorderCodec {
    static const List<int> magic = [0x4D, 0x58, 0x45, 0x4E, 0x43, 0x31];
    static const int version = 1;
    static const int nonceBytes = 12;
    static const int tagBytes = 16;
    static const int chunkBytes = 1 << 20; // 1 MiB plaintext segments

    final AesGcm _cipher = AesGcm.with256bits();

    Future<SecretKey> generateDataKey() => _cipher.newSecretKey();

    Uint8List _chunkNonce(Uint8List baseNonce, int counter) {
        final nonce = Uint8List.fromList(baseNonce);
        nonce[8] = (counter >> 24) & 0xff;
        nonce[9] = (counter >> 16) & 0xff;
        nonce[10] = (counter >> 8) & 0xff;
        nonce[11] = counter & 0xff;
        return nonce;
    }

    /// Encrypts [plaintext] with [dataKey], returning the full container.
    /// [wrappedKey] is the DEK wrapped by the platform keystore; it is
    /// embedded so the file is self-describing.
    Future<Uint8List> encryptBytes(
        List<int> plaintext, {
        required SecretKey dataKey,
        required List<int> wrappedKey,
        required Uint8List baseNonce,
    }) async {
        if (baseNonce.length != nonceBytes) {
            throw ArgumentError.value(
                baseNonce.length,
                'baseNonce',
                'Expected a $nonceBytes-byte nonce',
            );
        }
        if (wrappedKey.length > 0xffff) {
            throw ArgumentError.value(
                wrappedKey.length,
                'wrappedKey',
                'Wrapped key exceeds 65535 bytes',
            );
        }

        final out = BytesBuilder();
        out.add(magic);
        out.addByte(version);
        out.add(baseNonce);
        out.addByte(wrappedKey.length & 0xff);
        out.addByte((wrappedKey.length >> 8) & 0xff);
        out.add(wrappedKey);

        var counter = 0;
        for (var offset = 0;
            offset < plaintext.length;
            offset += chunkBytes, ++counter) {
            final end = (offset + chunkBytes > plaintext.length)
                ? plaintext.length
                : offset + chunkBytes;
            final box = await _cipher.encrypt(
                plaintext.sublist(offset, end),
                secretKey: dataKey,
                nonce: _chunkNonce(baseNonce, counter),
            );
            out.addByte(box.cipherText.length & 0xff);
            out.addByte((box.cipherText.length >> 8) & 0xff);
            out.addByte((box.cipherText.length >> 16) & 0xff);
            out.addByte((box.cipherText.length >> 24) & 0xff);
            out.add(box.cipherText);
            out.add(box.mac.bytes);
        }
        return out.takeBytes();
    }

    /// Decrypts a container produced by [encryptBytes].
    /// [unwrap] resolves the embedded wrapped key into a plaintext DEK.
    Future<Uint8List> decryptBytes(
        List<int> container, {
        required Future<SecretKey> Function(List<int> wrappedKey) unwrap,
    }) async {
        if (container.length < magic.length + 15) {
            throw const FormatException('Container too small');
        }
        var cursor = 0;
        for (final expected in magic) {
            if (container[cursor++] != expected) {
                throw const FormatException('Bad container magic');
            }
        }
        if (container[cursor++] != version) {
            throw const FormatException('Unsupported container version');
        }
        final baseNonce = Uint8List.fromList(
            container.sublist(cursor, cursor + nonceBytes),
        );
        cursor += nonceBytes;
        final wrappedLength =
            container[cursor] | (container[cursor + 1] << 8);
        cursor += 2;
        final wrappedKey = container.sublist(cursor, cursor + wrappedLength);
        cursor += wrappedLength;
        final dataKey = await unwrap(wrappedKey);

        final out = BytesBuilder();
        var counter = 0;
        while (cursor < container.length) {
            if (cursor + 4 > container.length) {
                throw const FormatException('Truncated chunk header');
            }
            final length = container[cursor] |
                (container[cursor + 1] << 8) |
                (container[cursor + 2] << 16) |
                (container[cursor + 3] << 24);
            cursor += 4;
            if (cursor + length + tagBytes > container.length) {
                throw const FormatException('Truncated chunk body');
            }
            final box = SecretBox(
                container.sublist(cursor, cursor + length),
                nonce: _chunkNonce(baseNonce, counter),
                mac: Mac(
                    container.sublist(cursor + length,
                        cursor + length + tagBytes),
                ),
            );
            cursor += length + tagBytes;
            final plain = await _cipher.decrypt(box, secretKey: dataKey);
            out.add(plain);
            ++counter;
        }
        return out.takeBytes();
    }
}

/// Cross-platform secure recorder.
///
/// PCM capture is delegated to a [PcmCapture] — Android's AudioRecord
/// pipeline on mobile, the `record`-backed [DesktopMicBroker] on
/// desktop — and the AES-256-GCM DEK is wrapped by a [DataKeyWrap]
/// (Android Keystore / OS secure storage). The `.mxenc` container
/// layout is identical on every platform.
class SecureRecorder {
    SecureRecorder({
        MethodChannel platform =
            const MethodChannel('aura.straton.maxima/accessibility'),
        SecureRecorderCodec? codec,
        PcmCapture? capture,
        DataKeyWrap? keyWrap,
        DesktopMicBroker? broker,
    })  : _codec = codec ?? SecureRecorderCodec(),
          _capture = capture ??
              defaultPcmCapture(platform: platform, broker: broker),
          _keyWrap = keyWrap ?? defaultKeyWrap(platform: platform);

    final SecureRecorderCodec _codec;
    final PcmCapture _capture;
    final DataKeyWrap _keyWrap;

    /// Starts PCM capture. Returns false when the platform rejects the
    /// request (e.g. missing microphone permission).
    Future<bool> start() => _capture.start();

    /// Stops capture, encrypts the PCM into [destinationPath], and
    /// returns the number of plaintext bytes sealed. Returns 0 when no
    /// audio was captured.
    Future<int> stopAndSeal({
        required String destinationPath,
    }) async {
        final pcmPath = await _capture.stop();
        if (pcmPath == null || pcmPath.isEmpty) return 0;

        final pcmFile = File(pcmPath);
        if (!await pcmFile.exists()) return 0;
        final plaintext = await pcmFile.readAsBytes();
        if (plaintext.isEmpty) {
            await pcmFile.delete();
            return 0;
        }

        final dataKey = await _codec.generateDataKey();
        final dekBytes = await dataKey.extractBytes();
        final wrappedKey = await _keyWrap.wrap(dekBytes);

        final nonce = Uint8List.fromList(
            List<int>.generate(
                SecureRecorderCodec.nonceBytes,
                (_) => _randomByte(),
            ),
        );
        final container = await _codec.encryptBytes(
            plaintext,
            dataKey: dataKey,
            wrappedKey: wrappedKey,
            baseNonce: nonce,
        );

        final destination = File(destinationPath);
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(container, flush: true);
        await pcmFile.delete();
        return plaintext.length;
    }

    /// Decrypts a sealed recording into [destinationPath].
    Future<void> unseal({
        required String sealedPath,
        required String destinationPath,
    }) async {
        final container = await File(sealedPath).readAsBytes();
        final plaintext = await _codec.decryptBytes(
            container,
            unwrap: (wrapped) async => SecretKey(await _keyWrap.unwrap(wrapped)),
        );
        final destination = File(destinationPath);
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(plaintext, flush: true);
    }

    static int _randomByte() => _rand.nextInt(256);
    static final _rand = Random.secure();
}
