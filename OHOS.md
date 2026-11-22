# HarmonyOS（鸿蒙）构建与移植说明

本仓库在 [ch6vip/novel-sound](https://github.com/ch6vip/novel-sound) 的 GPL-3.0 源码基础上，
增加了 **HarmonyOS（鸿蒙）** 端的完整实现：ArkTS 平台插件、Rust 核心的 OHOS 交叉编译、
hvigor 工程与真机运行链路。

- 目标系统：HarmonyOS 5.0 及以上（当前开发验证于 **HarmonyOS 26 / API 26** 真机）
- 设备要求：arm64-v8a（**x86_64 模拟器未验证**）
- 应用包名：`com.shijinpu.fqapp`

> 当前进度：**M1 已完成**——应用可安装、可启动、可加载真实内容（Rust 核心 + 环回 HTTP + TLS 全通）。
> 视频播放、听书（系统朗读）等原生通道按里程碑 M2/M3 推进，详见本文末「进度与已知限制」。

---

## 1. 工具链

| 组件 | 版本 / 位置 | 说明 |
| --- | --- | --- |
| Flutter | `3.50.0+ohos-1.3.1`（Dart 3.14.0） | **必须使用鸿蒙版 Flutter**，官方 Flutter 不支持 `TargetPlatform.ohos` |
| HarmonyOS SDK | API 26（`sdk-pkg.json` → `apiVersion: 26`） | 路径**不能含空格**，见下方「SDK 路径」 |
| DevEco Studio | 261.23567.138.36.2600865 | 只用其自带 hvigor / ohpm / node / JBR |
| Rust | 1.100.0 + target `aarch64-unknown-linux-ohos` | `rustup target add aarch64-unknown-linux-ohos` |

鸿蒙版 Flutter 有两条社区维护线，本仓库在
[oh-flutter](https://atomgit.com/oh-flutter/flutter_flutter) 的 `release/3.50.0+ohos-1.3.1` 上验证：

```bash
git clone -b release/3.50.0+ohos-1.3.1 https://atomgit.com/oh-flutter/flutter_flutter.git
```

> 官方 [CPF-Flutter](https://gitcode.com/CPF-Flutter/flutter_flutter) 线同样可用，但稳定版最高为
> 3.41.9（Dart 3.11），低于本项目 `pubspec.yaml` 要求的 Dart `^3.12.2`；用 3.47+ 即可。

### SDK 路径不能含空格

ring / cc-rs 会把 `CFLAGS` 按空格切分，路径里带空格时汇编阶段直接失败
（`clang: error: no such file or directory: 'Files\DevEco'`）。所以不要直接把 DevEco 安装目录
下的 SDK 指给构建，而是复制到无空格路径：

```powershell
robocopy "D:\App\DevEco Studio\sdk" "D:\ohsdk" /E /MT:16
```

---

## 2. 一次性准备

```powershell
# 1) pub 缓存放到与工程同盘：hvigor 在跨盘符时会把插件路径退化成绝对路径并报
#    AdaptorError 00303231: The srcPath is not a relative path
$env:PUB_CACHE = 'D:\pub-cache'

# 2) 每次构建都要设的环境变量
$env:PATH = "D:\flutter-ohos\bin;C:\Program Files\Git\cmd;D:\App\DevEco Studio\tools\node;" +
            "D:\App\DevEco Studio\tools\ohpm\bin;D:\App\DevEco Studio\tools\hvigor\bin;" +
            "D:\ohsdk\default\openharmony\toolchains;$env:PATH"
$env:DEVECO_SDK_HOME   = 'D:\ohsdk'
$env:HOS_SDK_HOME      = 'D:\ohsdk'
$env:OHOS_SDK_HOME     = 'D:\ohsdk\default\openharmony'
$env:JAVA_HOME         = 'D:\App\DevEco Studio\jbr'
$env:PUB_HOSTED_URL    = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
```

```powershell
flutter pub get
# 3) 第三方 UI 包补丁（见下节，必须执行）
dart run tool/patch_ohos_packages.dart
```

### 第三方 UI 包补丁（重要）

Flutter 3.47+ 把 Material / Cupertino 拆成了 `material_ui` / `cupertino_ui` 两个 pub 包，
它们对 `TargetPlatform` 写的是穷尽 switch，而鸿蒙版 Flutter 的枚举多了一个 `ohos`。
干净的 pub 缓存会在 Dart kernel 阶段直接失败（约 77 处 `not exhaustively matched`）。

`tool/patch_ohos_packages.dart` 会在 pub 缓存里给这两个包补上 ohos 分支（幂等，可重复运行）：

```powershell
dart run tool/patch_ohos_packages.dart          # 打补丁
dart run tool/patch_ohos_packages.dart --check  # 只检查（CI 用，缺补丁时退出码 1）
```

> 这是临时手段：等上游发布 ohos-aware 版本后应删除该脚本并升级依赖。
> 脚本只改本机 pub 缓存，不会改动仓库文件。

---

## 3. 构建

```powershell
# Rust 核心：交叉编译 + 复制 .so 进 ohos/entry/libs/arm64-v8a/
powershell -File .\scripts\build_rust_backend_ohos.ps1 -SkipCodegen

# Flutter + 鸿蒙工程：产出已签名 HAP
flutter build hap --debug
```

产物：`ohos/entry/build/default/outputs/default/entry-default-signed.hap`（约 210 MB，debug）。

- 首次构建若 `ohos/build-profile.json5` 里 `signingConfigs` 为空，hvigor 会走
  **Auto-signing**，浏览器登录华为开发者账号后自动生成调试证书并回写该文件。
  该文件里的签名材料是本机的，**不要提交**。
- 只打包 `ohos/entry/libs/arm64-v8a/` 下的 `.so`；改了 Rust 代码必须先跑上面的脚本，
  否则装到设备上的还是旧库（表现为 `Failed to load dynamic library 'libfqapi_core.so'`）。

## 4. 安装到真机

```powershell
$hdc = 'D:\ohsdk\default\openharmony\toolchains\hdc.exe'
& $hdc install ohos\entry\build\default\outputs\default\entry-default-signed.hap
& $hdc shell aa start -a EntryAbility -b com.shijinpu.fqapp

# 日志（应用日志域 0xF0A0）
& $hdc shell "hilog -x | grep -E 'A0F0A0'"
# 截图（后缀必须是 .jpeg）
& $hdc shell "snapshot_display -f /data/local/tmp/shot.jpeg"
& $hdc file recv /data/local/tmp/shot.jpeg .\shot.jpeg
```

---

## 5. 架构要点

```
Flutter (Dart)  ─┬─ Rust 核心 libfqapi_core.so（网络/签名/解密/CENC 索引/环回服务）
                 ├─ ArkTS 插件（FlutterPlugin）：secure_keys、native_player…
                 └─ NAPI 模块 libfq_native.so（纹理 → AVPlayer surfaceId 桥接）
```

- Rust 侧 `aarch64-unknown-linux-ohos` 的 `target_os` 就是 `linux`，因此设备池密钥走
  Linux 严格分支——密钥必须由 Dart 在启动时通过 FRB `set_device_pool_key` 下发。
- 解密后的明文视频通过 Rust 内置的环回 HTTP 服务（`127.0.0.1:18921`）以 Range 分块提供，
  播放器不需要任何解密代码；`127.0.0.1` 的明文 HTTP 在鸿蒙上无需额外 `network_config`。
- **密钥库用 Asset Store Kit**（`@ohos.security.asset`），不是 HUKS：
  API 26 真机上 HUKS 的对称会话只能加密、无法解密（`401` / `12000012`），
  写进去重启后解不开。Asset Store 等价 iOS Keychain，应用不接触密钥材料。

---

## 6. 进度与已知限制

| 能力 | 状态 |
| --- | --- |
| 首页 / 榜单 / 分类 / 书架 | ✅ 可用 |
| 阅读器（正文、进度、缓存） | ✅ 可用 |
| 本机密钥库（设备池密钥、Hive 密钥） | ✅ 可用（Asset Store Kit） |
| 视频 / 短剧播放 | ⏳ M2：`FqPlayerPlugin`（AVPlayer + 外接纹理，PoC 已验证 184 ms 首帧） |
| 听书 / 系统朗读 | ⏳ M2/M3：`native_player` 音频 + `fqapp/system_tts`（Core Speech Kit） |
| 后台播放 / 媒体通知 | ⏳ M2（长时任务 + AVSession，PoC 已验证） |
| 画中画（PiP） | ⏳ M2（PiP 走 XComponent，需播放器双输出，PoC 已验证） |
| 悬浮窗（小窗播放） | ⛔ 鸿蒙手机不开放全局悬浮窗权限，改为 PiP |
| 微信赞赏 / 支持作者 | ⏸ 尚未启用（关于页暂不展示该卡片） |

在播放器实现之前，视频与听书入口会按 `lib/services/platform_capabilities.dart` 的判断
显示「暂不支持」，不会崩溃。