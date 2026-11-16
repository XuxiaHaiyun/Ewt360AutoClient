import 'package:ewt_auto_client/features/player/domain/entities/report_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReportConfig 自定义模式字段', () {
    test('默认值: customEnabled=false, customScript 为空', () {
      const c = ReportConfig();
      expect(c.customEnabled, isFalse);
      expect(c.customScript, isEmpty);
    });

    test('自定义模式配置序列化往返', () {
      const script = 'async function main() { log("hi"); }';
      const c = ReportConfig(customEnabled: true, customScript: script);
      final json = c.toJson();
      expect(json['customEnabled'], isTrue);
      expect(json['customScript'], script);

      final restored = ReportConfig.fromJson(json);
      expect(restored.customEnabled, isTrue);
      expect(restored.customScript, script);
    });

    test('fromJson 缺失自定义字段回退默认', () {
      final c = ReportConfig.fromJson({'filterCompleted': true});
      expect(c.customEnabled, isFalse);
      expect(c.customScript, isEmpty);
      // 其余既有字段不受影响
      expect(c.heartbeatInterval, 60);
      expect(c.completionThreshold, 0.8);
    });

    test('fromJson 非法 customScript 类型回退空串', () {
      final c = ReportConfig.fromJson({'customScript': 123});
      expect(c.customScript, isEmpty);
    });
  });

  group('ReportConfig V7 任意用户进度注入', () {
    test('默认值: injectUserId=false, 目标为空', () {
      const c = ReportConfig();
      expect(c.injectUserId, isFalse);
      expect(c.injectTargetUserId, isEmpty);
      // 未开启时 effectiveInjectUserId 恒为 null
      expect(c.effectiveInjectUserId, isNull);
    });

    test('开启且目标为纯数字 → effectiveInjectUserId 返回目标', () {
      const c = ReportConfig(
        injectUserId: true,
        injectTargetUserId: '161621588',
      );
      expect(c.effectiveInjectUserId, '161621588');
    });

    test('开启但目标为空/非数字 → 视为非法, 返回 null', () {
      const empty = ReportConfig(injectUserId: true);
      expect(empty.effectiveInjectUserId, isNull);
      const nonNumeric = ReportConfig(
        injectUserId: true,
        injectTargetUserId: 'abc123',
      );
      expect(nonNumeric.effectiveInjectUserId, isNull);
    });

    test('目标带空白 → effectiveInjectUserId 返回去空白值', () {
      const c = ReportConfig(
        injectUserId: true,
        injectTargetUserId: ' 161621588 ',
      );
      expect(c.effectiveInjectUserId, '161621588');
    });

    test('注入配置序列化往返', () {
      const c = ReportConfig(
        injectUserId: true,
        injectTargetUserId: '999999999',
      );
      final json = c.toJson();
      expect(json['injectUserId'], isTrue);
      expect(json['injectTargetUserId'], '999999999');

      final restored = ReportConfig.fromJson(json);
      expect(restored.injectUserId, isTrue);
      expect(restored.injectTargetUserId, '999999999');
      expect(restored.effectiveInjectUserId, '999999999');
    });

    test('fromJson 缺失注入字段回退默认 (关闭)', () {
      final c = ReportConfig.fromJson({'filterCompleted': true});
      expect(c.injectUserId, isFalse);
      expect(c.injectTargetUserId, isEmpty);
      expect(c.effectiveInjectUserId, isNull);
    });
  });
}
