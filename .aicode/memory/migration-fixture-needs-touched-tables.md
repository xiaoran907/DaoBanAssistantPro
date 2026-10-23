---
name: migration-fixture-needs-touched-tables
description: "给迁移分支加 addColumn 后，必须给所有「from >= 该表创建版本」的测试 fixture 补上那张表，否则 SqliteException: no such table"
---
# 迁移分支 addColumn 必须同步补测试 fixture 的表

## 坑
`test/migration_v*_test.dart` 的 fixture 是**手工 DDL**，只建「迁移分支会访问到的表」，不是全量 schema。给 `app_database.dart` 的 `onUpgrade` 加一个 `m.addColumn(<表>, <列>)` 之后，所有「from >= 该表创建版本」的 fixture 都必须补上那张表，否则会抛：

```
SqliteException(1): while executing, no such table: <表名>, SQL logic error (code 1)
```

## v0.12.2 踩过一次
schemaVersion 14→16 时加了 `if (from < 15) { if (from >= 6) m.addColumn(shiftClassRows, extraSegments) }`，导致 **10 条**测试从绿变红（`migration_v10_to_v11`、`v10_to_v14`、`v11_to_v13`、`v12_to_v13` 共 4 个文件）。全量测试从 1136/8 变成 1125/19。

修法：给那 4 个 fixture 各补一份 `shift_class_rows` 的 CREATE TABLE。**故意不含** `extra_segments` 列 —— 那一列正是迁移要加上去的。

## 判断哪些 fixture 要补
遍历所有 `test/migration_*_test.dart`，读它的 `PRAGMA user_version = N`，凡是 `N >= <表的创建版本>` 的都要补：

```bash
for f in test/migration_*_test.dart; do
  v=$(grep -oE "user_version = [0-9]+" "$f" | grep -oE "[0-9]+" | head -1)
  echo "$(basename $f): from=$v  <表名>=$(grep -c "CREATE TABLE <表名>" "$f")"
done
```

⚠️ 分支判断方向容易搞错：`if (from < 11)` 对 from=12 是 **false**（12 不小于 11）。所以 from=12 的 fixture **不需要** `schedule_events`（`from < 11` 那条不执行），只需要 `shift_class_rows`（`from < 15` 那条会执行）。

## 已有的先例
这个模式在代码里已经出现过两次，注释写得明明白白：
- `custom_templates` 只有 v9 及以后才有 → v8 及更早的 fixture 由 `from < 9` 按当前 schema 建表
- `shift_class_rows` 只有 v6 及以后才有 → `migration_v5_to_v6_test.dart` 正是拦这个的
- `migration_v12_to_v13_test.dart` 的注释原话：「真实 v12 库一定有这张表，fixture 就得有 —— 这与当年给更早的 fixture 补 `schedule_events` 是同一条。」

## 顺带：硬编码的 schemaVersion 断言
`migration_v10_to_v11_test.dart` 和 `migration_v10_to_v14_test.dart` 里有 `expect(db.schemaVersion, 14)`，注释写着「每加一版 schema 都要回来改」。升版后必须同步改这两个数字。