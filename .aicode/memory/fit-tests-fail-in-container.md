---
name: fit-tests-fail-in-container
description: 容器里 flutter test 有 8 条布局 fit 测试恒红（环境缺 Roboto/中文字体，TextPainter 测量不准）——这是预先存在的，不是回归
---
# 容器里 flutter test 恒红的 8 条布局测试

## 现象
在这台容器里跑 `flutter test`，稳定有 **8 条**失败，日志开头会有提示：

```
[visual] 字体缺 拉丁(Roboto) / 图标(MaterialIcons)，缺的部分会渲染成方块
```

失败的 8 条（2026-10-23 实测，v0.12.2）：
- `calendar_header_fit_test.dart`：标准档 360dp：顶栏一行，年月完整
- `info_card_fit_test.dart`：一屏构图 360dp · large / · extraLarge / · 特大 · 英文
- `info_card_fit_test.dart`：矮屏 320dp 特大只保证不省略 · en
- `list_subtitle_fit_test.dart`：待办副标题折两行，不省略 · zh / · en
- `label_value_row_test.dart`：编辑器的字段标签与值 · 320dp 特大 · en

## 根因
这些用例全用 `TextPainter` / `FittedBox` / 固定件宽度做**排版实测**判断。容器里没有 Roboto 与中文字体，测量结果与真机差得很远（`calendar_screen.dart` 自己的注释里量过：同一个「2026年10月」兜底字体 128px、真字体 86px）。

典型症状：`_oneRowFits` 判成放不下 → 顶栏走两行档 → 断言找 `Key('header-single-row')` 得到 0 个 widget。

## 已验证是预先存在，不是回归
用 `git worktree add --detach /tmp/v0121_check HEAD` 在干净的 v0.12.1+176 上跑同样这 4 个文件，**失败的是完全相同的 8 条**。所以判断新改动的测试结果时，基线是「除这 8 条外全绿」，不是「全绿」。

对照方法：
```bash
git worktree add --detach /tmp/check HEAD
cd /tmp/check/app && flutter pub get
flutter test test/info_card_fit_test.dart test/list_subtitle_fit_test.dart \
  test/label_value_row_test.dart test/calendar_header_fit_test.dart
git worktree remove --force /tmp/check
```

## 不要做的事
- 不要为了让它绿而改这些测试（那是在掩盖真机的布局回归）。
- 不要改 `_oneRowFits` 这类判据去迁就容器。
- 出包前不必为了这 8 条额外处理 —— 真机上有字体，这些是正常的。