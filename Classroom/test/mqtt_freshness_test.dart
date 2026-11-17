import 'package:flutter_test/flutter_test.dart';
import 'package:smart_classroom_iot/services/mqtt_service.dart';

void main() {
  group('vision MQTT freshness', () {
    const now = 1800000000000;

    test('accepts a fresh snapshot before its four-second expiry', () {
      expect(
        MqttService.isFreshVisionState({
          'sent_at_unix_ms': now - 1000,
          'expires_at_unix_ms': now + 3000,
          'occupancy': {'observation_valid': true},
        }, nowMs: now),
        isTrue,
      );
    });

    test('rejects an expired or un-timestamped snapshot', () {
      expect(
        MqttService.isFreshVisionState({
          'sent_at_unix_ms': now - 5000,
          'expires_at_unix_ms': now - 1000,
          'occupancy': {'observation_valid': true},
        }, nowMs: now),
        isFalse,
      );
      expect(
        MqttService.isFreshVisionState({'occupancy': {}}, nowMs: now),
        isFalse,
      );
    });

    test('accepts the explicit offline will without occupancy freshness', () {
      expect(
        MqttService.isFreshVisionState({
          'occupancy': {'status': 'OFFLINE', 'online': false},
        }, nowMs: now),
        isTrue,
      );
      expect(
        MqttService.isFreshVisionState({
          'status': 'OFFLINE',
          'online': false,
          'occupancy': {'count': null},
        }, nowMs: now),
        isTrue,
      );
    });
  });
}
