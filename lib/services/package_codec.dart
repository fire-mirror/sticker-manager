import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptedPackageCodec {
  static const _magic = <int>[0x53, 0x4d, 0x50, 0x01];
  static const _saltLength = 16;

  Future<Uint8List> encrypt(List<int> plain, String password) async {
    if (password.length < 8) throw ArgumentError('密码至少需要 8 个字符');
    final salt = Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => Random.secure().nextInt(256)),
    );
    final key = await _deriveKey(password, salt);
    final box = await AesGcm.with256bits().encrypt(plain, secretKey: key);
    return Uint8List.fromList([..._magic, ...salt, ...box.concatenation()]);
  }

  Future<Uint8List> decrypt(List<int> bytes, String password) async {
    if (bytes.length < _magic.length + _saltLength ||
        !_magic
            .asMap()
            .entries
            .every((entry) => bytes[entry.key] == entry.value)) {
      throw const FormatException('不是有效的 Sticker Manager 迁移包');
    }
    final salt = bytes.sublist(_magic.length, _magic.length + _saltLength);
    final encrypted = bytes.sublist(_magic.length + _saltLength);
    final key = await _deriveKey(password, salt);
    final algorithm = AesGcm.with256bits();
    final box = SecretBox.fromConcatenation(
      encrypted,
      nonceLength: algorithm.nonceLength,
      macLength: algorithm.macAlgorithm.macLength,
    );
    return Uint8List.fromList(await algorithm.decrypt(box, secretKey: key));
  }

  Future<SecretKey> _deriveKey(String password, List<int> salt) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }
}
