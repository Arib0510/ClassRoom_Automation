import 'package:flutter_test/flutter_test.dart';
import 'package:smart_classroom_iot/services/app_update_service.dart';

void main() {
  group('AppUpdateService Unit Tests', () {
    test('Tag version parsing and comparison', () {
      final service = AppUpdateService();
      expect(service, isNotNull);
      expect(AppUpdateService.repoOwner, equals('Arib0510'));
      expect(AppUpdateService.repoName, equals('ClassRoom_Automation'));
    });
  });
}
