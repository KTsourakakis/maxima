import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps a per-recording AES-256 data-encryption key (DEK) with the best
/// platform mechanism available.
///
/// The opaque blob returned by [wrap] is embedded in the `.mxenc`
/// container header; [unwrap] resolves it back to the plaintext DEK.
abstract class DataKeyWrap {
    /// Produces the opaque blob stored inside the container header.
    Future<Uint8List> wrap(List<int> dek);

    /// Resolves a stored blob back into the plaintext DEK.
    Future<Uint8List> unwrap(List<int> blob);
}

/// Mobile implementation: DEK is RSA-2048-OAEP wrapped by a
/// non-exportable platform key — Android Keystore (MaximaKeyVault.kt)
/// or the iOS Keychain (MaximaKeyVault.swift) — via the platform
/// method channel. The embedded blob layout is identical on both.
class PlatformChannelKeyWrap extends DataKeyWrap {
    PlatformChannelKeyWrap({
        MethodChannel platform =
            const MethodChannel('aura.straton.maxima/accessibility'),
    }) : _platform = platform;

    final MethodChannel _platform;

    @override
    Future<Uint8List> wrap(List<int> dek) async {
        final wrappedB64 = await _platform.invokeMethod<String>(
            'wrapDataKey',
            {'key': base64Encode(dek)},
        );
        if (wrappedB64 == null) {
            throw StateError('Android Keystore wrap is unavailable');
        }
        return base64Decode(wrappedB64);
    }

    @override
    Future<Uint8List> unwrap(List<int> blob) async {
        final b64 = await _platform.invokeMethod<String>(
            'unwrapDataKey',
            {'wrapped': base64Encode(blob)},
        );
        if (b64 == null) {
            throw StateError('Android Keystore unwrap is unavailable');
        }
        return base64Decode(b64);
    }
}

/// Desktop implementation backed by `flutter_secure_storage`:
///
///  - Windows: credential is stored via the Windows Credential Manager /
///    DPAPI-protected storage used by the plugin.
///  - macOS:  the Keychain.
///  - Linux:  the Secret Service API (libsecret / gnome-keyring /
///    KDE Wallet) when available.
///
/// Instead of embedding a wrapped key, the container header stores a
/// `MXSS1:<id>` locator; the DEK itself stays inside the OS secure
/// store under `maxima_dek_<id>`. Unwrapping on a different device or
/// profile therefore fails safely.
class SecureStorageKeyWrap extends DataKeyWrap {
    SecureStorageKeyWrap({FlutterSecureStorage? storage})
        : _storage = storage ?? const FlutterSecureStorage();

    static const String _locatorPrefix = 'MXSS1:';
    static const String _keyPrefix = 'maxima_dek_';

    final FlutterSecureStorage _storage;
    static final Random _rand = Random.secure();

    static String _newId() =>
        List<int>.generate(16, (_) => _rand.nextInt(256))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();

    @override
    Future<Uint8List> wrap(List<int> dek) async {
        final id = _newId();
        await _storage.write(
            key: '$_keyPrefix$id',
            value: base64Encode(dek),
        );
        return Uint8List.fromList(utf8.encode('$_locatorPrefix$id'));
    }

    @override
    Future<Uint8List> unwrap(List<int> blob) async {
        final locator = utf8.decode(blob, allowMalformed: true);
        if (!locator.startsWith(_locatorPrefix)) {
            throw const FormatException('Not a secure-storage key locator');
        }
        final id = locator.substring(_locatorPrefix.length);
        final b64 = await _storage.read(key: '$_keyPrefix$id');
        if (b64 == null) {
            throw StateError(
                'Recording key not present in the OS secure store',
            );
        }
        return base64Decode(b64);
    }
}

/// Platform dispatch: Android/iOS use the Keystore/Keychain channel
/// wrapper; desktop targets use the OS secure storage provider.
DataKeyWrap defaultKeyWrap({
    MethodChannel platform =
        const MethodChannel('aura.straton.maxima/accessibility'),
    FlutterSecureStorage? storage,
}) {
    if (Platform.isAndroid || Platform.isIOS) {
        return PlatformChannelKeyWrap(platform: platform);
    }
    return SecureStorageKeyWrap(storage: storage);
}
