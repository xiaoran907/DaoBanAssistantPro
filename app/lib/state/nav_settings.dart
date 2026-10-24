import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底栏 tab 的稳定标识符（与语言、文案无关）。
///
/// 持久化到 SharedPreferences，重启后恢复。
/// 关掉 = 隐藏 + 后台任务停止，历史数据保留。
enum NavTabId {
  calendar,
  alarm,
  todo,
  salary,
  profile;

  String get key => name;
}

/// 底栏 tab 配置：哪些 tab 启用、以什么顺序排列。
class NavTabConfig {
  const NavTabConfig({
    this.enabled = const {
      NavTabId.calendar,
      NavTabId.alarm,
      NavTabId.todo,
      NavTabId.salary,
      NavTabId.profile,
    },
    this.order = const [
      NavTabId.calendar,
      NavTabId.alarm,
      NavTabId.todo,
      NavTabId.salary,
      NavTabId.profile,
    ],
  });

  final Set<NavTabId> enabled;
  final List<NavTabId> order;

  bool isEnabled(NavTabId id) => enabled.contains(id);

  /// 按 [order] 排序后的启用 tab 列表。
  List<NavTabId> get activeTabs {
    return order.where((id) => enabled.contains(id)).toList();
  }

  bool get isAlarmEnabled => enabled.contains(NavTabId.alarm);
  bool get isTodoEnabled => enabled.contains(NavTabId.todo);

  NavTabConfig copyWith({Set<NavTabId>? enabled, List<NavTabId>? order}) {
    return NavTabConfig(
      enabled: enabled ?? this.enabled,
      order: order ?? this.order,
    );
  }

  NavTabConfig toggleEnabled(NavTabId id) {
    final next = Set<NavTabId>.from(enabled);
    if (next.contains(id)) {
      // 不允许全部关掉（至少留一个 tab）
      if (next.length <= 1) return this;
      next.remove(id);
    } else {
      next.add(id);
    }
    return copyWith(enabled: next);
  }

  NavTabConfig reorder({required NavTabId id, required int newIndex}) {
    final next = List<NavTabId>.from(order);
    final oldIndex = next.indexOf(id);
    if (oldIndex < 0 || oldIndex == newIndex) return this;
    next.removeAt(oldIndex);
    final clamped = newIndex.clamp(0, next.length);
    next.insert(clamped, id);
    return copyWith(order: next);
  }

  String toJson() => jsonEncode({
        'enabled': enabled.map((e) => e.key).toSet().toList(),
        'order': order.map((e) => e.key).toList(),
      });

  static NavTabConfig fromJson(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final enabledList = (map['enabled'] as List<dynamic>? ?? [])
          .map((e) => NavTabId.values.firstWhere((v) => v.key == e,
              orElse: () => throw ArgumentError()))
          .toSet();
      final orderList = (map['order'] as List<dynamic>? ?? [])
          .map((e) => NavTabId.values.firstWhere((v) => v.key == e,
              orElse: () => throw ArgumentError()))
          .toList();
      if (enabledList.isEmpty || orderList.isEmpty) {
        return const NavTabConfig();
      }
      return NavTabConfig(enabled: enabledList, order: orderList);
    } catch (_) {
      return const NavTabConfig();
    }
  }
}

final navSettingsProvider =
    StateNotifierProvider<NavSettingsNotifier, NavTabConfig>((ref) {
  return NavSettingsNotifier();
});

class NavSettingsNotifier extends StateNotifier<NavTabConfig> {
  NavSettingsNotifier() : super(const NavTabConfig()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('navConfig');
      if (raw != null) {
        state = NavTabConfig.fromJson(raw);
      }
    } catch (_) {}
  }

  Future<void> reload() => _load();

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('navConfig', state.toJson());
  }

  Future<void> setEnabled(NavTabId id, bool enabled) async {
    final next = state.copyWith(
      enabled: enabled
          ? {...state.enabled, id}
          : state.enabled.difference({id}),
    );
    state = next;
    await _save();
  }

  Future<void> reorder({required NavTabId id, required int newIndex}) async {
    state = state.reorder(id: id, newIndex: newIndex);
    await _save();
  }

  void resetToDefaults() {
    state = const NavTabConfig();
  }
}
