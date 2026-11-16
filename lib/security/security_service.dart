import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class SecurityService {
  SecurityService._();
  static final SecurityService instance = SecurityService._();
  final _storage = const FlutterSecureStorage();
  final _auth = LocalAuthentication();
  final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );

  Future<bool> get hasPin async =>
      await _storage.read(key: 'gops_pin_hash') != null;
  Future<bool> get biometricEnabled async =>
      (await _storage.read(key: 'gops_biometric')) == 'true';

  Future<void> createPin(String pin) async {
    if (!RegExp(r'^\d{6,}$').hasMatch(pin))
      throw ArgumentError('Le PIN doit contenir au moins 6 chiffres.');
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final secret = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    await _storage.write(key: 'gops_pin_salt', value: base64Encode(salt));
    await _storage.write(
      key: 'gops_pin_hash',
      value: base64Encode(await secret.extractBytes()),
    );
  }

  Future<bool> verifyPin(String pin) async {
    final storedHash = await _storage.read(key: 'gops_pin_hash');
    final storedSalt = await _storage.read(key: 'gops_pin_salt');
    if (storedHash == null || storedSalt == null) return false;
    final secret = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: base64Decode(storedSalt),
    );
    final computed = await secret.extractBytes();
    final expected = base64Decode(storedHash);
    var diff = computed.length ^ expected.length;
    for (var i = 0; i < min(computed.length, expected.length); i++) {
      diff |= computed[i] ^ expected[i];
    }
    return diff == 0;
  }

  Future<bool> authenticateBiometrically() async {
    try {
      if (!await _auth.canCheckBiometrics && !await _auth.isDeviceSupported())
        return false;
      return await _auth.authenticate(
        localizedReason: 'Déverrouiller GOPS',
        biometricOnly: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometric(bool enabled) =>
      _storage.write(key: 'gops_biometric', value: '$enabled');
  Future<int> lockTimeoutMinutes() async =>
      int.tryParse(await _storage.read(key: 'gops_lock_minutes') ?? '') ?? 5;
  Future<void> setLockTimeoutMinutes(int minutes) =>
      _storage.write(key: 'gops_lock_minutes', value: '$minutes');
  Future<int> failedAttempts() async =>
      int.tryParse(await _storage.read(key: 'gops_failed_attempts') ?? '') ?? 0;
  Future<void> recordFailure() async => _storage.write(
    key: 'gops_failed_attempts',
    value: '${(await failedAttempts()) + 1}',
  );
  Future<void> resetFailures() async =>
      _storage.write(key: 'gops_failed_attempts', value: '0');
}
