import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/api/api_config.dart';

void main() {
  group('compiledApiBaseUrlDefine', () {
    test('prefers UPANEL_API_BASE_URL over API_URL', () {
      expect(
        compiledApiBaseUrlDefine(
          upanelApiBaseUrl: 'https://kiu.orion13.us',
          apiUrl: 'https://api.kiu.orion13.us',
        ),
        'https://kiu.orion13.us',
      );
    });

    test('uses API_URL when UPANEL_API_BASE_URL is empty', () {
      expect(
        compiledApiBaseUrlDefine(
          upanelApiBaseUrl: '',
          apiUrl: 'https://api.kiu.orion13.us',
        ),
        'https://api.kiu.orion13.us',
      );
    });
  });

  group('resolveUPanelApiBaseUrl', () {
    test('uses dart-define on native when web runtime is absent', () {
      expect(
        resolveUPanelApiBaseUrl(
          compiled: 'https://api.kiu.orion13.us',
        ),
        'https://api.kiu.orion13.us',
      );
    });

    test('strips trailing slash', () {
      expect(
        resolveUPanelApiBaseUrl(
          compiled: 'https://api.kiu.orion13.us/',
        ),
        'https://api.kiu.orion13.us',
      );
    });

    test('web runtime origin wins over compiled define', () {
      expect(
        resolveUPanelApiBaseUrl(
          compiled: 'https://api.kiu.orion13.us',
          runtimeWeb: 'https://kiu.orion13.us',
        ),
        'https://kiu.orion13.us',
      );
    });

    test('falls back to local Django', () {
      expect(
        resolveUPanelApiBaseUrl(compiled: ''),
        'http://127.0.0.1:8000',
      );
    });
  });
}
