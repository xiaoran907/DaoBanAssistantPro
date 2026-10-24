import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiftassistantpro/state/nav_settings.dart';

void main() {
  test('默认配置：全部启用、默认顺序', () {
    const config = NavTabConfig();
    expect(config.enabled.length, 5);
    expect(config.isEnabled(NavTabId.calendar), isTrue);
    expect(config.isEnabled(NavTabId.alarm), isTrue);
    expect(config.isEnabled(NavTabId.todo), isTrue);
    expect(config.isEnabled(NavTabId.salary), isTrue);
    expect(config.isEnabled(NavTabId.profile), isTrue);
    expect(config.activeTabs, [
      NavTabId.calendar,
      NavTabId.alarm,
      NavTabId.todo,
      NavTabId.salary,
      NavTabId.profile,
    ]);
    expect(config.isAlarmEnabled, isTrue);
    expect(config.isTodoEnabled, isTrue);
  });

  test('JSON 序列化与反序列化往返一致', () {
    const config = NavTabConfig(
      enabled: {NavTabId.calendar, NavTabId.todo, NavTabId.profile},
      order: [NavTabId.profile, NavTabId.calendar, NavTabId.alarm,
          NavTabId.todo, NavTabId.salary],
    );
    final decoded = NavTabConfig.fromJson(config.toJson());
    expect(decoded.enabled, config.enabled);
    expect(decoded.order, config.order);
  });

  test('JSON 解析非法字符串时回退默认', () {
    final decoded = NavTabConfig.fromJson('not json');
    expect(decoded, const NavTabConfig());
  });

  test('JSON 解析空 enabled 或 order 时回退默认', () {
    final decoded = NavTabConfig.fromJson('{"enabled":[],"order":["calendar"]}');
    expect(decoded, const NavTabConfig());
  });

  test('toggleEnabled 关掉一个 tab', () {
    final config = const NavTabConfig()
        .toggleEnabled(NavTabId.alarm);
    expect(config.isEnabled(NavTabId.alarm), isFalse);
    expect(config.isEnabled(NavTabId.calendar), isTrue);
    expect(config.activeTabs, [
      NavTabId.calendar,
      NavTabId.todo,
      NavTabId.salary,
      NavTabId.profile,
    ]);
  });

  test('toggleEnabled 重新打开一个 tab', () {
    final config = const NavTabConfig()
        .toggleEnabled(NavTabId.alarm)
        .toggleEnabled(NavTabId.alarm);
    expect(config.isEnabled(NavTabId.alarm), isTrue);
  });

  test('不能关掉最后一个 tab', () {
    const config = NavTabConfig(
      enabled: {NavTabId.calendar},
      order: [NavTabId.calendar, NavTabId.alarm, NavTabId.todo,
          NavTabId.salary, NavTabId.profile],
    );
    final result = config.toggleEnabled(NavTabId.calendar);
    expect(result, config);
  });

  test('reorder 交换两个相邻 tab', () {
    const config = NavTabConfig();
    final result = config.reorder(id: NavTabId.alarm, newIndex: 0);
    expect(result.order.first, NavTabId.alarm);
    expect(result.order[1], NavTabId.calendar);
  });

  test('reorder 移到末尾', () {
    const config = NavTabConfig();
    final result = config.reorder(id: NavTabId.calendar, newIndex: 4);
    expect(result.order.last, NavTabId.calendar);
  });

  test('reorder 同一位置不动', () {
    const config = NavTabConfig();
    final result = config.reorder(id: NavTabId.calendar, newIndex: 0);
    expect(result, config);
  });

  test('NavSettingsNotifier 设置后状态正确', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(navSettingsProvider.notifier);

    await notifier.setEnabled(NavTabId.alarm, false);
    expect(container.read(navSettingsProvider).isEnabled(NavTabId.alarm),
        isFalse);

    await notifier.setEnabled(NavTabId.alarm, true);
    expect(container.read(navSettingsProvider).isEnabled(NavTabId.alarm),
        isTrue);
  });

  test('NavSettingsNotifier reorder 后状态正确', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(navSettingsProvider.notifier);

    await notifier.reorder(id: NavTabId.alarm, newIndex: 0);
    expect(container.read(navSettingsProvider).order.first,
        NavTabId.alarm);
  });

  test('toJson 输出可被 fromJson 正确解析', () {
    const config = NavTabConfig(
      enabled: {NavTabId.calendar, NavTabId.profile},
      order: [NavTabId.profile, NavTabId.calendar, NavTabId.alarm,
          NavTabId.todo, NavTabId.salary],
    );
    final decoded = NavTabConfig.fromJson(config.toJson());
    expect(decoded.isEnabled(NavTabId.alarm), isFalse);
    expect(decoded.order.first, NavTabId.profile);
  });

  test('resetToDefaults 恢复默认', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(navSettingsProvider.notifier);

    notifier.setEnabled(NavTabId.alarm, false);
    expect(container.read(navSettingsProvider).isEnabled(NavTabId.alarm),
        isFalse);

    notifier.resetToDefaults();
    expect(container.read(navSettingsProvider), const NavTabConfig());
  });
}
