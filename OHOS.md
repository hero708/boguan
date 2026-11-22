# HarmonyOS（鸿蒙）构建与移植说明

本仓库在 [ch6vip/novel-sound](https://github.com/ch6vip/novel-sound) 的 GPL-3.0 源码基础上，
增加了 **HarmonyOS（鸿蒙）** 端的完整实现：ArkTS 平台插件、Rust 核心的 OHOS 交叉编译、
hvigor 工程与真机运行链路。

- 目标系统：HarmonyOS 5.0 及以上（当前开发验证于 **HarmonyOS 26 / API 26** 真机）
- 设备要求：arm64-v8a（**x86_64 模拟器未验证**）
- 应用包名：`com.shijinpu.fqapp`

> 当前进度：**M2 已完成**——应用可安装、可启动、可加载真实内容（Rust 核心 + 环回 HTTP + TLS 全通），
> **视频/短剧真机出画面、听书音频、系统朗读（离线 TTS）、后台播放与媒体通知**均已打通；
> 画中画（PiP）与悬浮窗小窗播放留待后续批次，详见本文末「进度与已知限制」。

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

产物：`build/ohos/hap/entry-default-signed.hap`（flutter 工具输出，约 220 MB，debug），
同一份也会镜像到 `ohos/entry/build/default/outputs/default/entry-default-signed.hap`。

- 首次构建若 `ohos/build-profile.json5` 里 `signingConfigs` 为空，hvigor 会走
  **Auto-signing**，浏览器登录华为开发者账号后自动生成调试证书并回写该文件。
  该文件里的签名材料是本机的，**不要提交**。
- 只打包 `ohos/entry/libs/arm64-v8a/` 下的 `.so`；改了 Rust 代码必须先跑上面的脚本，
  否则装到设备上的还是旧库（表现为 `Failed to load dynamic library 'libfqapi_core.so'`）。
- **不打包 `libc++_shared.so`**：`ohos/entry/build-profile.json5` 的
  `buildOption.nativeLib.filter.excludes` 已排除它。实测 HAP 内三个自有库的 NEEDED
  （`llvm-readelf -d`）都不依赖 libc++，排除后省 1.2 MB 且不影响加载。

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

> **换签名证书后必须先清数据再装**：本机密钥库（Asset Store）里的密钥与签名身份绑定，
> 直接覆盖安装会读不到旧密钥并生成新密钥，旧设备池文件因此 HMAC 校验失败，
> 启动页报 `encrypted pool file authentication failed`。处理：
> `hdc shell bm uninstall -n com.shijinpu.fqapp` 后再 `hdc install`。

---

## 5. 架构要点

```
Flutter (Dart)  ─┬─ Rust 核心 libfqapi_core.so（网络/签名/解密/CENC 索引/环回服务）
                 ├─ ArkTS 插件（FlutterPlugin）：secure_keys、native_player、system_tts…
                 └─ NAPI 模块 libfq_native.so（纹理 → AVPlayer surfaceId、Rust 媒体源桥接）
```

- 解密后的明文视频通过 Rust 内置的环回 HTTP 服务（`127.0.0.1:18921`）以 Range 分块提供，
  播放器不需要任何解密代码；`127.0.0.1` 的明文 HTTP 在鸿蒙上无需额外 `network_config`。
- Rust 侧 `aarch64-unknown-linux-ohos` 的 `target_os` 就是 `linux`，因此设备池密钥走
  Linux 严格分支——密钥必须由 Dart 在启动时通过 FRB `set_device_pool_key` 下发；
  `desktop_media`（CENC 解密 + 环回服务）也因此天然编进了 ohos 动态库，无需改 `cfg`。
- ArkTS 播放插件不自己解密：`fq_native.openMediaSource(url, key)` 通过 `dlopen("libfqapi_core.so")`
  调用 Rust 的 `fq_desktop_media_open`（随机 token 的 `127.0.0.1` 端口 + `/media/<token>`），
  把返回的环回 URL 交给 `AVPlayer`；`dispose` 时 `closeMediaSource(id)` 关闭会话。
  与桌面端（media_kit）走同一套 Rust 实现，明文源同样经过环回以便复用鉴权/重试/Range。
- 视频输出：`TextureRegistry.registerTexture()` → `SurfaceTextureEntry.getSurfaceId()`（数字，
  `FlutterRenderer` 内部就是 `flutterNapi.registerTexture` 的结果）→ `AVPlayer.surfaceId`；
  `libfq_native.getSurfaceId(nativeWindowPtr)` 保留为兜底。
- 后台听书：`UIAbilityContext`（`AbilityContextHolder` 在 `EntryAbility.onCreate` 里赋值）+
  `backgroundTaskManager.startBackgroundRunning(AUDIO_PLAYBACK)` + `avSession.createAVSession`。
  前台会话操作在 `FqPlayerPlugin` 内串行排队（`foregroundQueue`），避免
  `6600101 session is existed` / `9800005 already applied for a continuous task`。
- 系统朗读：`@kit.CoreSpeechKit` 的 `textToSpeech`（离线引擎，`person 13` = 聆小珊），
  无引擎枚举/无 pause/无字符回调 → `fqapp/system_tts` 只负责逐句 speak 并回
  `start`/`done`/`error` 事件；`engines()` 返回静态音色项以保证设置页可用。
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
| 视频 / 短剧播放 | ✅ 可用（M2：`FqPlayerPlugin`，AVPlayer + 外接纹理 + Rust 环回解密） |
| 听书音频（作品朗读音） | ✅ 可用（同 `FqPlayerPlugin`，`audioOnly` 不设 surfaceId） |
| 系统朗读（离线 TTS） | ✅ 可用（M2：`SystemTtsPlugin` + Core Speech Kit，逐句高亮推进） |
| 后台播放 / 媒体通知 | ✅ 可用（长时任务 + AVSession，切后台 TTS 继续） |
| 画中画（PiP） | ⏳ 未实现（需 XComponent 双输出，PoC 已验证可行） |
| 悬浮窗（小窗播放） | ⛔ 鸿蒙手机不开放全局悬浮窗权限，插件侧已软降级（`canDrawOverlays → false`），后续接 PiP |
| 微信赞赏 / 支持作者 | ⏸ 尚未启用（关于页暂不展示该卡片） |

已知限制与后续批次：

- **本地加密缓存回放**（`file://` + `keyHex`）尚未在真机验证：Rust 媒体源桥接支持本地路径，
  但下载链路本身仍是 M3 范围；未下载的在线集不受影响。
- **桌面平台代码未做条件隔离**：Dart 没有按操作系统区分的条件导入键，`desktop_platform.dart`
  被 27 个文件直接引用，真正隔离需要把桌面 UI shell 与平台标志整体拆包并给 ohos 单独入口，
  属结构性重构。当前 ohos 构建不注册桌面包、HAP 内也没有桌面依赖的 `.so`，功能上无影响。
- 系统朗读的**语速/音量**由离线引擎管理，应用侧只记录值，暂不能逐应用调速。
- 系统朗读没有「引擎设置页」可跳转，设置页按钮会提示不支持（系统设置里可调音量）。
