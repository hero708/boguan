<p align="center">
  <img src="assets/images/app_logo.webp" width="120" alt="博观">
</p>

<h1 align="center">博观</h1>

<p align="center">
  <strong>让阅读和追剧，简单一点。</strong><br>
  小说 · 听书 · 短剧 · 漫剧 · 漫画
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android%20%7C%20Windows%20%7C%20HarmonyOS-087E8B" alt="支持 Android、Windows 和鸿蒙">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue" alt="GPL-3.0 开源协议"></a>
  <img src="https://img.shields.io/badge/HarmonyOS-M2%20%E5%B7%B2%E5%AE%8C%E6%88%90-E89B35" alt="鸿蒙端 M2 已完成">
</p>

<p align="center">
  <a href="#主要功能">主要功能</a> ·
  <a href="#平台支持">平台支持</a> ·
  <a href="#构建与开发">构建与开发</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="OHOS.md">鸿蒙说明</a> ·
  <a href="DEVELOPMENT.md">开发文档</a>
</p>

---

## 关于本项目

**博观** 是开源项目 [ch6vip/novel-sound](https://github.com/ch6vip/novel-sound) 的派生版本（遵循 GPL-3.0）。

在保留原版全部功能的基础上，本仓库：

- 将应用更名为 **博观**，重新整理了文档与构建说明；
- 新增 **HarmonyOS（鸿蒙）原生端**：ArkTS 插件 + Rust 核心交叉编译 + hvigor 工程，当前 **M2 已完成**（视频/短剧、听书、系统朗读、后台播放与媒体通知）；
- 修复移植过程中暴露的播放器与系统服务问题（前台会话串行化、纹理 surfaceId 桥接等）。

原版项目、作者与社区信息见文末「致谢与许可」。本仓库不冒充原版，也不代表原作者的观点或承诺。

> <p align="center">
>   <img src=".github/screenshots/m2/drama-player.jpeg" width="240" alt="鸿蒙真机短剧播放">
>   <img src=".github/screenshots/m2/reader-tts.jpeg" width="240" alt="鸿蒙真机系统朗读">
>   <img src=".github/screenshots/m2/tts-settings.jpeg" width="240" alt="鸿蒙系统朗读设置">
> </p>
> <p align="center"><sub>鸿蒙端真机截图：短剧播放 · 系统朗读高亮 · 朗读引擎选择（M2）</sub></p>

## 主要功能

### 📖 看小说，听故事

- 在线阅读小说，也能导入 TXT / EPUB 电子书。
- 字体、字号、翻页方式随心调，支持深色、纯黑和墨水屏模式。
- 支持系统朗读和真人有声书，可调倍速、定时停止、后台播放。

### 🎬 追短剧，看漫画

- 短剧、漫剧、漫画集中浏览，按作品名称或编号搜索。
- 自动保存阅读和播放进度，下次打开接着看。

### 📚 整理书架，离线慢慢看

- 收藏喜欢的作品，分组整理，导出备份后可在新设备恢复。
- 提前下载内容，没网时继续阅读或播放。

## 平台支持

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| 安卓 | ✅ 沿用原版 | Android 7.0 及以上，构建见 [DEVELOPMENT.md](DEVELOPMENT.md) |
| Windows | ✅ 沿用原版 | Windows 10 / 11 64 位，见 [WINDOWS.md](WINDOWS.md) |
| **鸿蒙** | ✅ **M2 已完成** | HarmonyOS 真机可安装运行，见 [OHOS.md](OHOS.md) |
| Linux | ⏳ 社区移植 | 见 [LINUX.md](LINUX.md) |
| iOS | ⏳ 未完成 | 见 [IOS.md](IOS.md) |

### 鸿蒙端进度（M2）

- ✅ 视频 / 短剧播放：AVPlayer + Flutter 外部纹理（`SurfaceTexture.getSurfaceId()` 直接作为 `surfaceId`）
- ✅ 加密媒体：Rust 核心的 CENC 解密与 loopback 服务在设备内运行，`AVPlayer` 播放 `127.0.0.1` 本地源
- ✅ 听书：服务端音频（智能朗读）与离线**系统朗读**（Core Speech Kit，person 聆小珊）
- ✅ 后台播放与媒体通知：长时任务（`KEEP_BACKGROUND_RUNNING` + `audioPlayback`）+ AVSession
- ⚠️ 悬浮窗：鸿蒙不开放全局悬浮窗，插件按软降级返回「不支持」，入口不出现
- ⏳ 画中画（PiP）：需要 `XComponent` 双输出，PoC 已验证可行，尚未实现
- ⏳ 本地加密缓存（`file://` + 密钥）回放：尚未验证
- ℹ️ 已知限制：系统朗读的语速/音量由系统决定（无逐应用控制），鸿蒙未提供朗读引擎设置页

## 构建与开发

本仓库目前不附带预编译安装包，请按文档自行构建：

| 目标 | 文档 |
| --- | --- |
| Windows / Linux 桌面 | [WINDOWS.md](WINDOWS.md) · [LINUX.md](LINUX.md) |
| 安卓 | [DEVELOPMENT.md](DEVELOPMENT.md) |
| iOS | [IOS.md](IOS.md) |
| **鸿蒙** | [OHOS.md](OHOS.md)（工具链、一次性准备、构建、安装、签名注意事项） |

鸿蒙端构建要素（摘要）：

- Flutter 3.50.0 + OHOS 适配版、DevEco Studio（hvigor）、`D:\ohsdk`（路径不要带空格）
- Rust 交叉编译到 `aarch64-unknown-linux-ohos`，产物 `.so` 放入 `ohos/entry/libs/arm64-v8a/`
- `flutter build hap --debug` → `build/ohos/hap/entry-default-signed.hap`，用 `hdc install` 安装

更完整的环境变量、第三方包补丁、日志与截图方法见 [OHOS.md](OHOS.md)。

## 开始使用

1. **找作品**：在首页浏览，或搜索作品名称、编号。
2. **导入自己的书**：在书架菜单选择「导入图书」，打开 TXT / EPUB 文件。
3. **下载小说**：在作品详情点「下载」，在「我的 → 离线缓存」管理已下载内容。

看小说时点击屏幕中间，可以调整阅读设置。主题和听书选项在「我的 → 设置」；经典主题点击右上角齿轮。

## 常见问题

<details>
<summary><b>没网也能用吗？</b></summary>

可以看已导入的电子书、读已缓存的章节、播放已下载的媒体。只有已下载完成的内容才能离线使用，搜索和获取新内容仍需要联网。启动时可选择「离线阅读」。

</details>

<details>
<summary><b>一直加载、搜索失败或播放不了，怎么办？</b></summary>

先检查网络，换个网络或重启应用再试。在线内容依赖第三方服务，对方调整或网络波动可能导致暂时不可用。

持续失败请在 [Issues](https://github.com/hero708/boguan/issues) 反馈，附上应用版本、设备型号（例如「鸿蒙 / HarmonyOS 26」）、作品名称或编号，以及错误截图。

</details>

<details>
<summary><b>使用代理或广告过滤时提示设备注册连接失败，重试无效？</b></summary>

首次使用在线内容时，应用需要通过 HTTPS 连接 `log.snssdk.com:443` 完成上游设备注册。部分广告过滤规则会把该域名归为日志服务并拒绝连接；在规则未改变时，重复点击重试仍会失败。该提示也可能由 DNS、连接或上游服务异常引起，不能仅凭 TLS 错误断定被拦截。

无需关闭代理、TUN/VPN 或全部广告过滤。先在代理／DNS 过滤工具中查看该域名的请求记录；如果明确命中拒绝规则，仅为 **`log.snssdk.com`** 添加允许例外，优先于拒绝规则，并继续使用你选择的出口。不要放行整个 `snssdk.com` 域名族。

对于 Clash / Mihomo，将精确域名规则插入现有 `rules` 列表并置于广告拒绝规则之前，策略选用你已有的适用出口：

```yaml
prepend:
  - DOMAIN,log.snssdk.com,DIRECT
```

若该域名需要经代理连接，把 `DIRECT` 换成你已有的代理策略组名称。DNS 层过滤也需要添加精确域名例外。应用按配置使用网络出口，不会自动改写过滤规则、绕过显式代理或忽略证书校验；若允许后仍失败，请反馈应用版本、失败时间及脱敏后的域名／命中规则（不要公开代理订阅、凭据或设备标识）。

</details>

<details>
<summary><b>换设备怎么搬书架和进度？</b></summary>

在「我的 → 备份与导入」导出备份文件，传到新设备后选择「从备份文件恢复」，预览并确认。

也可以使用 WebDAV 云同步：在「我的 → 备份与导入 → WebDAV 同步」填写地址、用户名和密码，保存并立即同步；新设备执行同样操作即可。

备份包含收藏、书架分组、阅读和播放进度、已看剧集；不包含本地电子书、下载缓存、阅读时长、划线和设置。导出前先退出阅读或暂停播放，让进度保存，本地书文件请单独保留。

</details>

<details>
<summary><b>系统朗读没有声音？</b></summary>

检查媒体音量，并确认设备安装了语音引擎和中文音色。安卓 / Windows 可在「设置 → 听书 → 系统朗读」选择可用语音；Windows 用户可在系统语音设置中安装中文音色。

鸿蒙端使用系统内置的 Core Speech Kit 离线引擎（聆小珊等），初次朗读前请确认系统「设置 → 声音」中的语速与音量正常；鸿蒙没有提供第三方朗读引擎设置页，引擎内暂不支持逐应用调语速。

</details>

<details>
<summary><b>鸿蒙端安装后提示「启动失败 / encrypted pool file authentication failed」？</b></summary>

这是本地数据与签名证书不匹配导致的。鸿蒙把密钥存放在与签名身份绑定的安全存储里，**换了签名证书（例如从正式包切到调试自动签名）后，旧的池文件无法解密**。处理方式是清数据重装：

```powershell
hdc shell bm uninstall -n com.shijinpu.fqapp
hdc install .\build\ohos\hap\entry-default-signed.hap
```

注意：卸载会清除本地书、缓存与阅读进度，重要数据请先备份。详见 [OHOS.md](OHOS.md) 的安装章节。

</details>

## 参与与贡献

- 使用中遇到问题、想要新功能：到本仓库 [Issues](https://github.com/hero708/boguan/issues) 反馈。
- 想一起改代码：见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [DEVELOPMENT.md](DEVELOPMENT.md)。
- **原版功能相关问题**（与原版一致的阅读、下载、账号体系等）建议先到 [上游项目](https://github.com/ch6vip/novel-sound/issues) 检索，可能已有答案。
- 鸿蒙相关的问题、构建失败与移植建议，欢迎直接提到本仓库，附 `hilog` 摘要（`hilog -x | grep A0F0A0`）与设备型号。

本派生版本没有官方交流群或赞助渠道；如果你想支持原版作者，请前往原仓库。

## 致谢与许可

- 原版项目：[ch6vip/novel-sound](https://github.com/ch6vip/novel-sound)（作者 ch6vip 及贡献者），本仓库在其基础上派生并重命名。
- 界面参考：[Wenku8 界面项目](assets/licenses/wenku8/PORTING.md)；社区：[LINUX DO](https://linux.do/)。
- 项目采用 [GPL-3.0](LICENSE) 开源协议，Copyright © 2026 ch6vip；本仓库的鸿蒙端与相关修改由 hero708 维护，同样以 GPL-3.0 发布。

在线内容来自第三方，版权归各自权利人。本项目与内容提供方无隶属关系，不托管作品，不绕过付费或访问权限。

书架、进度和缓存保存在设备上。如开启 AI 校对或云端同步，相关内容会发送到你选择的服务，使用前请阅读应用内说明。
