import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  print('--- Testing Qwen ASR Authentication & Connection ---');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    print('1. Testing Login to Demo Account...');
    final loginReq = await client.postUrl(Uri.parse('https://asr.ieeio.com/api/v1/auth/login'));
    loginReq.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    loginReq.headers.set('User-Agent', 'Pilipala-Client');
    loginReq.add(utf8.encode(jsonEncode({
      'email': 'demo@asrclient.dev',
      'password': 'demo123456',
    })));
    final loginRes = await loginReq.close().timeout(const Duration(seconds: 8));
    print('Login Status Code: ${loginRes.statusCode}');
    final loginBody = await utf8.decoder.bind(loginRes).join();
    print('Login Response: $loginBody');

    if (loginRes.statusCode == 200) {
      final data = jsonDecode(loginBody) as Map<String, dynamic>;
      final token = data['accessToken'] as String?;
      print('Token obtained: ${token != null ? (token.substring(0, 10) + "...") : "null"}');

      if (token != null) {
        print('2. Testing Realtime Config Request...');
        final configReq = await client.getUrl(Uri.parse('https://asr.ieeio.com/api/v1/meeting/transcription/realtime/config'));
        configReq.headers.set('Authorization', 'Bearer $token');
        configReq.headers.set('Origin', 'https://asr.ieeio.com');
        final configRes = await configReq.close().timeout(const Duration(seconds: 8));
        print('Config Status Code: ${configRes.statusCode}');
        final configBody = await utf8.decoder.bind(configRes).join();
        print('Config Response: $configBody');
      }
    }
  } catch (e) {
    print('Error: $e');
  } finally {
    client.close();
  }
}
