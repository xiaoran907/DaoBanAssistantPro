---
name: container-release-build-aapt2
description: 容器内构建 release APK 的必查项：AGP 9.1 调 aapt2 参数形式不匹配会产出「缺 AndroidManifest/resources.arsc 但 BUILD SUCCESSFUL」的坏包，必须验 APK 本体；不能绕过 flutter 直接跑 gradle
---
# 容器内构建 release APK：两个静默失败坑

环境：arm64 PRoot 容器，Flutter 3.47.7，AGP 9.1.0，Gradle 9.3.1，SDK 35/36，JDK 21。
构建命令：`flutter build apk --release --target-platform android-arm64`

## 坑 1：AGP 9.1 与 AOSP aapt2 的参数形式不匹配（APK 缺 manifest，Gradle 仍报成功）

**症状**：`BUILD SUCCESSFUL`，但 APK 里**没有 `AndroidManifest.xml` 和 `resources.arsc`**
（条目数只有 86 个、体积偏小），`aapt2 dump badging` 报 `could not identify format of APK`。
dex / so / assets / kotlin_builtins 全在，**签名块也在**，所以极易误判为成功。

**根因**：AGP 9.x 以 `--resource-path-shortening-map=<path>`（**等号形式**）调用 `aapt2 optimize`，
而 SDK build-tools 里的 AOSP aapt2（`2.19-compiler260819000427`）只接受
`--resource-path-shortening-map <path>`（**空格形式**）。实测：
- 等号形式 → `unknown option '--resource-path-shortening-map=/x'`，exit=1
- 空格形式 → exit=0

aapt2 daemon **吞掉子进程退出码**，于是 `:app:optimizeReleaseResources` 无任何报错、
无任何产物（目录里只剩 `output-metadata.json`），Gradle 判定成功，
`packageRelease` 拿不到资源包照常打包 → 坏 APK。
这是 Android 上设备构建（Termux / 容器）特有的，Google 打包的 aapt2 不会触发。

**已做的修复（容器工具链，不改项目文件）**：把
`/root/android/sdk/build-tools/35.0.0/aapt2` 和 `36.0.0/aapt2` 改名为 `aapt2.real`，
同路径放 bash 包装脚本，只翻译 `--resource-path-shortening-map=V` → `--resource-path-shortening-map V`，
其余参数原样透传，`exec "$dir/aapt2.real" "${args[@]}"`。
两份脚本内容相同，靠 `dirname $0` 定位真实二进制。

⚠️ **容器重建后这个包装会丢失**，坑会重现。同理还有 `gen_snapshot` 的 qemu 包装（见另一条记忆）。

**改完必须让任务真正重跑**：只改 aapt2 不够，Gradle 任务历史仍认为 outputs 已就绪。
要 `rm -rf build/app/intermediates/optimized_processed_res`（删输出目录强制 not up-to-date），
否则 `flutter build` 会 90 秒后照样产出同一个坏 APK。

**以后验证 release 包，只看 Gradle 的 `✓ Built` 不够**，务必验 APK 本体：

```bash
A=app/build/app/outputs/flutter-apk/app-release.apk
unzip -l $A | grep -cE "AndroidManifest\.xml|resources\.arsc"   # 必须 = 2
unzip -l $A | grep -E "^.*lib/" | awk '{print $4}' | cut -d/ -f1-2 | sort -u   # ABI 白名单
/root/android/sdk/build-tools/35.0.0/aapt2 dump badging $A | grep -E "native-code|versionCode"
/root/android/sdk/build-tools/35.0.0/apksigner verify --verbose --print-certs $A   # Verifies + 证书 DN
```

## 坑 2：不能绕过 flutter 直接跑 gradle

`./gradlew :app:packageRelease --rerun-tasks` 会失败：`compileFlutterBuildRelease` 报
`Failed to find ".../android-arm-release/linux-arm64/gen_snapshot"`（还有 android-x64）。
因为 flutter 是通过 `-Ptarget-platform=android-arm64` 限制 ABI 的，直接跑 gradle 时该属性缺失，
Flutter 就按默认编全部 3 个 ABI，而另外两个 ABI 的 `gen_snapshot` 没补。
**验证单个打包任务也只能通过 flutter 跑**，或在 gradle 命令行补 `-Ptarget-platform=android-arm64`。

## 内存

容器 MemTotal 11.4G，`gradle.properties` 配的是 `-Xmx8G -XX:MaxMetaspaceSize=4G`（合计超总量）。
完整 `flutter build` 能跑完（约 110s），但 `--rerun-tasks` 全量重跑会被 OOM 静默杀掉
（进程直接消失，无任何日志、无 EXIT 标记）。需要限时/限内存时用
`-Dorg.gradle.jvmargs="-Xmx3g -XX:MaxMetaspaceSize=1g"`。

## 其它已确认事实

- 工作区**没有** `key.properties` / keystore，release 包一律是 **debug 证书**签名
  （DN `C=US, O=Android, CN=Android Debug`，SHA-256 `6c5bf069...`），
  不能覆盖安装任何正式签名的版本。
- 国内镜像：`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`
  （`download.flutter.io` 从本容器 TLS 握手被远端掐断）。
- `unzip -l` 的 `-c` 计数法可快速判断坏包：条目数 86 = 坏，612 = 正常。