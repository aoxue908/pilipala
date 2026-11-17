import 'dart:convert';
import 'dart:typed_data';

/// Edge-TTS Sec-MS-GEC DRM Token 生成器
/// 完全对齐 Microsoft Edge Read Aloud 协议规范与 Python edge-tts v2 算法
class EdgeTtsDrm {
  static const int _winEpoch = 11644473600;
  static const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const int _u32Mask = 0xFFFFFFFF;
  static final BigInt _bigMask = BigInt.from(0xFFFFFFFF);

  static const List<int> _sha256Initial = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
  ];

  static const List<int> _sha256State = [
    0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
    0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
  ];

  static const List<int> _sha256Schedule = [
    0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
    0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
    0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
    0xD258B060, 0x72766564,
  ];

  static const List<int> _sha256RoundConstants = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
  ];

  static const int _sha256Adjustment = 0xC9DC06A7;
  static final List<int> _sha256BlockConstants = [
    ..._sha256RoundConstants.sublist(0, 14),
    _sha256Adjustment,
    ..._sha256RoundConstants.sublist(15),
  ];

  static const int _sha256Sigma0Adjustment = 0x059C0B80;
  static const int _sha256Sigma1Adjustment = 0x000B92C0;

  static const List<List<int>> _cs64Coefficients = [
    [0xE82E91B1, 0xB32700D0],
    [0x44DE24C6, 0x88DFF51D],
    [0x3BEB65BC, 0x29514038],
    [0xC89C5933, 0xB328CBDF],
    [0x8D1EC211, 0xD405B4D5],
    [0x314EF5D5, 0x26E55F3C],
    [0xE92491B1, 0x607801C6],
    [0xF0A5B9D5, 0x82B2C1FB],
    [0x06064CF3, 0xFA51A3DA],
    [0xDA79FA60, 0x207CC464],
    [0xBED20560, 0x3C3C74F3],
    [0x89F9C9F8, 0xD2D14B61],
    [0x35FA38C6, 0xBB04A2C1],
    [0xCB49E3C6, 0xC5626167],
  ];

  static const int _cs64Factor = 0x82893933;
  static const int _cs64Adjustment0 = 0xF2F90B1A;
  static const int _cs64Adjustment1 = 0x0B1A0000;

  static int _mul(int a, int b) {
    return ((BigInt.from(a & _u32Mask) * BigInt.from(b & _u32Mask)) & _bigMask).toInt();
  }

  static int _rotr(int x, int n) {
    return ((x >>> n) | ((x << (32 - n)) & _u32Mask)) & _u32Mask;
  }

  static int _rol16(int value) {
    value &= _u32Mask;
    return (((value << 16) & _u32Mask) | (value >>> 16)) & _u32Mask;
  }

  static List<int> _wordsLe4Even(Uint8List data) {
    final padLen = (4 - (data.length % 4)) % 4;
    final padded = Uint8List(data.length + padLen);
    padded.setRange(0, data.length, data);
    final byteData = ByteData.sublistView(padded);
    final words = <int>[];
    for (var i = 0; i < padded.length; i += 4) {
      words.add(byteData.getUint32(i, Endian.little));
    }
    if (words.length % 2 != 0) {
      words.add(0);
    }
    return words;
  }

  static int _sigma0(int value) {
    return (_rotr(value, 7) ^ _rotr(value, 18) ^ (value >>> 3)) & _u32Mask;
  }

  static int _sigma1(int value) {
    return (_rotr(value, 17) ^ _rotr(value, 19) ^ (value >>> 10)) & _u32Mask;
  }

  static List<int> _sha256Rounds(List<int> state, List<int> words, [int firstRound = 0]) {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    final constants = firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;

    for (var index = firstRound; index < 64; index++) {
      final s1 = (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) & _u32Mask;
      final ch = (g ^ (e & (f ^ g))) & _u32Mask;
      final t1 = (h + s1 + ch + constants[index] + words[index]) & _u32Mask;
      final s0 = (_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) & _u32Mask;
      final maj = ((a & b) | (c & (a | b))) & _u32Mask;
      final t2 = (s0 + maj) & _u32Mask;

      h = g;
      g = f;
      f = e;
      e = (d + t1) & _u32Mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _u32Mask;
    }

    return [a, b, c, d, e, f, g, h];
  }

  static void _expandSha256Schedule(List<int> words, [int firstWord = 16]) {
    for (var index = firstWord; index < 64; index++) {
      final x = words[index - 2];
      final y = words[index - 15];
      final s1 = _sigma1(x);
      final s0 = _sigma0(y);
      words.add((s1 + words[index - 7] + s0 + words[index - 16]) & _u32Mask);
    }
  }

  static List<int> _sha256Init(Uint8List data) {
    final words = List<int>.filled(14, 0, growable: true);
    final w14 = (data[0] << 16) | (data[1] << 8) | data[2];
    final w15 = (data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6];
    words.add(w14);
    words.add(w15);

    for (var index = 16; index < 30; index++) {
      var value = _sha256Schedule[index - 16];
      if (index - 2 >= 14) {
        value += (index == 16 ? (_sigma1(words[index - 2]) ^ _sha256Sigma1Adjustment) : _sigma1(words[index - 2]));
      }
      if (index - 7 >= 14) {
        value += words[index - 7];
      }
      if (index - 15 >= 14) {
        value += (index == 29 ? (_sigma0(words[index - 15]) ^ _sha256Sigma0Adjustment) : _sigma0(words[index - 15]));
      }
      words.add(value & _u32Mask);
    }

    words.add((_sigma1(words[28]) +
            words[23] +
            _sigma0(words[15]) +
            words[14] +
            _sha256Adjustment -
            _sha256RoundConstants[14]) &
        _u32Mask);

    _expandSha256Schedule(words, 31);
    final working = _sha256Rounds(_sha256State, words, 14);
    return List<int>.generate(8, (i) => (_sha256Initial[i] + working[i]) & _u32Mask);
  }

  static Uint8List _sha256Digest(Uint8List data) {
    final length = 57 + data.length;
    final padLength = ((55 - length) % 64 + 64) % 64;
    final paddedList = <int>[...data.sublist(7), 0x80, ...List<int>.filled(padLength, 0)];

    final bitLength = length * 8;
    final lengthBytes = ByteData(8)..setUint64(0, bitLength, Endian.big);
    paddedList.addAll(lengthBytes.buffer.asUint8List());

    final padded = Uint8List.fromList(paddedList);
    var state = _sha256Init(data.sublist(0, 7));

    final byteData = ByteData.sublistView(padded);
    for (var offset = 0; offset < padded.length; offset += 64) {
      final words = <int>[];
      for (var i = 0; i < 64; i += 4) {
        words.add(byteData.getUint32(offset + i, Endian.big));
      }
      _expandSha256Schedule(words);
      final working = _sha256Rounds(state, words);
      state = List<int>.generate(8, (i) => (state[i] + working[i]) & _u32Mask);
    }

    final out = ByteData(32);
    for (var i = 0; i < 8; i++) {
      out.setUint32(i * 4, state[i], Endian.big);
    }
    return out.buffer.asUint8List();
  }

  static List<int> _cs64Digest(Uint8List data, Uint8List digest) {
    final digestBd = ByteData.sublistView(digest);
    var keyA = digestBd.getUint32(0, Endian.little) | 1;
    var keyB = digestBd.getUint32(4, Endian.little) | 1;

    final factorA = _mul(keyA, _cs64Factor);
    final factorB = _mul(keyB, _cs64Factor);
    final factors = [factorA, factorB];

    final terms = <int>[];
    for (var index = 0; index < _cs64Coefficients.length; index++) {
      final coef = _cs64Coefficients[index][0];
      final term = _mul(coef, factors[index % 2]);
      terms.add(term);
    }
    final offsets = _cs64Coefficients.map((e) => e[1]).toList();

    final dataPrefix = Uint8List(1 + data.length);
    dataPrefix[0] = 0;
    dataPrefix.setRange(1, dataPrefix.length, data);
    final words = _wordsLe4Even(dataPrefix);

    for (var index = 0; index < words.length; index++) {
      final word = words[index];
      var term = _mul(word, index % 2 == 0 ? keyA : keyB);
      var offset = _mul(_rol16(word), index % 2 == 0 ? 0xEF0569FB : 0xC31713DB);
      if (index == 0) {
        term = (term + _mul(_cs64Adjustment0, factors[0])) & _u32Mask;
        offset = (offset + _cs64Adjustment1) & _u32Mask;
      }
      terms.add(term);
      offsets.add(offset);
    }

    var swapAcc = 0;
    var swapLast = 0;
    var state = 0;
    var acc = 0;

    for (var index = 0; index < terms.length; index += 2) {
      final x = terms[index];
      final y = terms[index + 1];

      var t = _rol16((offsets[index] + x) & _u32Mask);
      var q = _mul(t, 0x76F50F34);
      swapAcc = (swapAcc + _mul(_rol16(q), 0xC3EFEA97) + q) & _u32Mask;

      t = _rol16((offsets[index + 1] + y) & _u32Mask);
      q = _mul(t, 0x1881CE3C);
      swapLast = (_mul(_rol16(q), 0x35BD1EC9) + q) & _u32Mask;
      swapAcc = (swapAcc + swapLast) & _u32Mask;

      state = (_mul(state, keyA) + x) & _u32Mask;
      state = _mul(_rol16(state), 0xCF98B111);
      state = _mul(_rol16(state), 0x87085B9F);
      state = _mul(_rol16(state), 0x12CEB96D);
      state = _mul(_rol16(state), 0x257E1D83);
      acc = (acc + state) & _u32Mask;

      t = (_mul(state, keyB) + y) & _u32Mask;
      t = _mul(_rol16(t), 0xA27416F5);
      t = _mul(_rol16(t), 0xD38396FF);
      state = _mul(_rol16(_mul(_rol16(t), 0x7C932B89)), 0xBFA49F69);
      acc = (acc + state) & _u32Mask;
    }

    return [
      (swapLast ^ state) & _u32Mask,
      (swapAcc ^ acc) & _u32Mask,
    ];
  }

  /// 生成 v2 Sec-MS-GEC Token
  static String generateSecMsGec([double? unixTimestamp]) {
    var ticks = unixTimestamp ?? (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0);
    ticks += _winEpoch;
    ticks -= ticks % 300;
    ticks *= 1e7; // 1e9 / 100 = 1e7

    final strToHash = '${ticks.toStringAsFixed(0)}$trustedClientToken';
    final data = Uint8List.fromList(ascii.encode(strToHash));

    final digest = _sha256Digest(data);
    final cs64Words = _cs64Digest(data, digest);

    final cs64Bytes = ByteData(8)
      ..setUint32(0, cs64Words[0], Endian.little)
      ..setUint32(4, cs64Words[1], Endian.little);

    final cs64Hex = cs64Bytes.buffer.asUint8List().map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final sha256Hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

    return '$cs64Hex-$sha256Hex';
  }
}
