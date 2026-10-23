// app/test/backup_roundtrip_test.dart
//
// 全量备份的编解码往返：
//  ① 导出再导入，15 张表逐行相等（含主键、可空列、DateTime）；
//  ② prefs 白名单跟着走，白名单之外的键不被碰；
//  ③ 格式校验：不是本应用的文件 / 来自更新版本的库 → 明确拒绝；
//  ④ 导入是「换数据」不是「重置」：库里原有的行先清光，不播种。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiftassistantpro/data/app_repository.dart';
import 'package:shiftassistantpro/data/backup.dart';
import 'package:shiftassistantpro/domain/payroll.dart';
import 'package:shiftassistantpro/domain/shift_rotation.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AppRepository(db);
    await repo.ensureSeeded();
  });
  tearDown(() => db.close());

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('导出 → 清库 → 导入：全部表逐行相等', () async {
    // 在种子之上再写一点「用户自己改的东西」：
    //  · 一条待办（含可空的提醒与联动闹钟开关）
    //  · 一条自定义闹钟
    //  · 一条按天改班覆盖
    //  · 薪资三张表
    await repo.addEvent(
        title: '交班', date: DateTime.utc(2025, 1, 6), timeMinute: 480);
    await repo.addCustomAlarm(
        hour: 6, minute: 30, repeatType: 0, onceDate: DateTime.utc(2025, 1, 7));
    final schedule = (await repo.getActiveSchedule())!;
    await repo.setDayOverrides([DateTime.utc(2025, 1, 6)],
        classId: schedule.classes.first.id!);
    await repo.setPayrollConfig(
        const PayrollConfig(monthlyWage: 320));
    await repo.setPayrollDayWage(DateTime.utc(2025, 1, 6), 640);
    await repo.savePayrollRecord(
        year: 2025, month: 1, actual: 5120, note: '工资');

    final sp = await prefsWith({
      'themeMode': 'dark',
      'accentIndex': 2,
      'language': 'zh',
      'liquidGlass': true,
      'hapticsEnabled': false,
      'fontSize': 'large',
      // ringtoneUri / ringtoneTitle 不设 = 没设过（备份里是 null，导进来的时
      // 候会把本机同名键抹掉）。
      'snoozeMinutes': 15,
      // 白名单之外：不该进备份，也不该被导入碰掉。
      'onboarded': true,
      'lastSeenVersion': '9.9.9',
    });

    final json = await buildBackupJson(db, prefs: sp, appVersion: '0.12.2');
    final parsed = parseBackupJson(json,
        currentSchemaVersion: db.schemaVersion);
    expect(parsed.prefs['themeMode'], 'dark');
    expect(parsed.prefs.containsKey('onboarded'), isFalse,
        reason: '流程状态不进备份');

    // 清库重灌（等价于导入的后半段）。
    await restoreParsedBackup(db, parsed.tables);

    // 排班那半边逐字段对上。
    final schedules = await db.select(db.shiftScheduleRows).get();
    expect(schedules, hasLength(1));
    expect(schedules.single.name, isNotEmpty);
    final classes = await db.select(db.shiftClassRows).get();
    final cycle = await db.select(db.shiftCycleRows).get();
    expect(classes, isNotEmpty);
    expect(cycle.map((c) => c.classId), everyElement(isIn(classes.map((c) => c.id))),
        reason: 'classId 的引用关系要一并保真');
    final overrides = await db.select(db.shiftDayOverrides).get();
    expect(overrides, hasLength(1));
    expect(overrides.single.day,
        dayNumber(DateTime.utc(2025, 1, 6)));

    final events = await db.select(db.scheduleEvents).get();
    expect(events.single.title, '交班');
    final alarms = await db.select(db.customAlarms).get();
    expect(alarms.single.hour, 6);

    // 薪资那半边。
    final settings = await db.select(db.payrollSettingsRows).get();
    expect(settings.single.monthlyWage, 320);
    final dayWages = await db.select(db.payrollDayRows).get();
    expect(dayWages.single.wage, 640);
    final records = await db.select(db.payrollRecordRows).get();
    expect(records.single.note, '工资');
  });

  test('导入 prefs：备份里的值覆盖本机；null 的键被抹回默认', () async {
    final sp = await prefsWith({
      'themeMode': 'light',
      'liquidGlass': false,
      'snoozeMinutes': 10,
    });
    await restoreBackupPrefs(sp, {
      'themeMode': 'dark',
      'liquidGlass': null, // 备份机上没设过 → 本机这个键抹掉
      'snoozeMinutes': 20,
    });
    expect(sp.getString('themeMode'), 'dark');
    expect(sp.getBool('liquidGlass'), isNull, reason: 'null = 回到默认');
    expect(sp.getInt('snoozeMinutes'), 20);
  });

  group('格式校验', () {
    test('不是 JSON / 不是本应用的备份 → BackupFormatException', () {
      expect(() => parseBackupJson('not json', currentSchemaVersion: 16),
          throwsA(isA<BackupFormatException>()));
      expect(
          () => parseBackupJson('{"app":"other"}',
              currentSchemaVersion: 16),
          throwsA(isA<BackupFormatException>()));
    });

    test('来自更新版本的库 → BackupTooNewException', () {
      const String future = '{"app":"shiftassistantpro","formatVersion":1,'
          '"schemaVersion":99,"tables":{}}';
      expect(() => parseBackupJson(future, currentSchemaVersion: 16),
          throwsA(isA<BackupTooNewException>()));
      // 老版本的备份（schema 更小）应该放行。
      const String older = '{"app":"shiftassistantpro","formatVersion":1,'
          '"schemaVersion":14,"tables":{}}';
      final parsed = parseBackupJson(older, currentSchemaVersion: 16);
      expect(parsed.tables, isEmpty);
    });
  });

  test('导入是换数据不是重置：原有的行先清光、不播种', () async {
    // 换一份「几乎全空」的数据进来（只带一条方案行，没有任何班次 / 周期）。
    await restoreParsedBackup(db, {
      'shift_schedule_rows': [
        {
          'id': 7,
          'name': '空表',
          'anchorDate': DateTime.utc(2025, 1, 1).millisecondsSinceEpoch,
          'isCurrent': true,
          'teamCount': 1,
          'teamNames': '我们',
          'ourTeamIndex': 0,
          'teamOffsets': '0',
          'monthly': false,
          'teamSegOffsets': '',
        }
      ],
    });

    final schedules = await db.select(db.shiftScheduleRows).get();
    expect(schedules, hasLength(1));
    expect(schedules.single.id, 7, reason: 'id 原样灌回');
    expect(await db.select(db.shiftClassRows).get(), isEmpty,
        reason: '种子里的班次不该残留');
    expect(await db.select(db.shiftClassAlarms).get(), isEmpty);
    expect(await db.select(db.customTemplates).get(), isEmpty);
    // _tablesOf 里登记了 15 张表：全都清空了（用方案行之外的两张抽查）。
    expect(await db.select(db.payrollSettingsRows).get(), isEmpty);
    expect(await db.select(db.recurringSeriesRows).get(), isEmpty);
  });
}
