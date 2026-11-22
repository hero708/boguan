# C 流式解密库

本目录是项目自行实现的 CENC MP4 流式解密库，替代之前只有二进制的外部依赖。
鸿蒙侧不再经过 JNI：`rust/build.rs` 用 `cc` 把 [crypto_core](crypto_core) 编进
`libfqapi_core.so`，Rust 侧直接调用 C 接口，播放器通过 flutter_rust_bridge 拿到解密流。

## 实现与范围

- [sp_stream.c](crypto_core/sp_stream.c)：只读取顶层 box 头和 `moov` 索引，跳过 `mdat`；
  播放时按需读取，每次最多 64 KiB，按加密样本/子样本交集解密。支持前置/尾置 `moov`、
  64 位偏移、多个 `mdat`、任意字节 seek，保持完整文件长度和所有数据偏移不变。
- [mp4_cenc.c](crypto_core/mp4_cenc.c)：验证每个父子 box 的边界、样本表、轨道间重叠、
  `tenc`、`senc` 和可选的 `saiz/saio`；恢复 `frma` 原格式，将保护信息改成等长 `free`。
- [sp_aes.c](crypto_core/sp_aes.c)：封装 [tiny-AES-c](third_party/tiny_aes/README.md) 的 AES-128。
  CTR 位置按每个样本已消耗的加密字节计算；clear 子样本不消耗密钥流。支持 8/16 字节 IV。
  第三方源码固定版本，原始 Unlicense 与文件哈希随源码保存。

首版支持非分片 MP4 的 `cenc` AES-CTR、单个内容密钥、内联 `senc`，包括加密音频和视频、
整样本与子样本加密、固定/逐样本 `stsz`、`stsc`、`stco/co64`。
不支持的分片 MP4、CBC/pattern 模式、密钥轮换、多个 KID、外置辅助加密数据、`stz2`、
加密轨的多个 sample description 等会明确报错。H.264、H.265 和 AAC 有真实媒体回归；
不能由这些测试推断所有编码格式或所有 CDN 文件均已验证。

`moov` 上限为 16 MiB，全文件累计最多 1,000,000 个样本、2,000,000 个子样本和
4,096 个顶层 box。内存主要用于有界的元数据索引，不随整集文件大小分配。
不会提前下载完整 `mdat`。拖动取消当前请求，后续 read 再从新偏移连接。

## 构建

[CMakeLists.txt](CMakeLists.txt) 只产出两个静态库（`sp_crypto_core`、`sp_audio_tempo`），
供 Rust 核心链接；鸿蒙包里的 `libfqapi_core.so` 由
`scripts/build_rust_backend_ohos.ps1` 交叉编译（目标 `aarch64-unknown-linux-ohos`）。
C 源码不含平台依赖，主机上用同一套 `cc` 编进 `rust/target/` 的主机库，供 Node 侧的
原生测试与 Rust 单测使用。

## I/O 与生命周期

`sp_stream_open` 成功后接管 `sp_io.user`；失败时仍由调用者清理。除 cancel 外，C 核心的
同一句柄操作必须串行，由 Rust 侧负责该串行化。read 在 EOF 返回 0，遇到错误返回负值；
seek 接受 `[0, size]`，失败不改变读取位置。Rust 把错误转成错误字符串，不会当作正常 EOF。

加密播放器由 Rust 播放核心打开媒体，不再另行预探测。待创建标记阻止已取消的请求分配播放器。
实际首次同步 open 在读取完元数据后才返回句柄；此阶段不能通过 `close(handle)` 提前取消，
网络操作仍需结束或触发传输超时。预热接口只进行元数据打开/关闭，不保留全局视频数据缓存。

## 验证

主机测试需要 Node.js、可执行本机程序的 C11 编译器，以及带 libx264/libx265/AAC 的 FFmpeg。
Windows 可用 Zig 的 `zig cc`，通过 `NATIVE_CC` 指定 `zig.exe`。

```powershell
$env:NATIVE_CC = 'C:\tools\zig\zig.exe'
node --test --test-concurrency=1 test/native_aes_test.cjs test/native_crypto_test.cjs test/native_crypto_media_test.cjs
```

Linux 内存与未定义行为检查：

```bash
NATIVE_CC=clang NATIVE_CFLAGS='-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer' \
  node --test --test-concurrency=1 test/native_aes_test.cjs test/native_crypto_test.cjs test/native_crypto_media_test.cjs
```

AES 对照使用 NIST 向量和 Node/OpenSSL；MP4 对照由 Node 独立加密、生成明文基准。
原生 driver 检查完整输出、随机 seek、短读、取消、错误、打开时未读取媒体数据，以及损坏输入变异。
FFmpeg 测试比较解密前后的每个 H.264/H.265 视频帧和 AAC 音频帧。
[GitHub Actions](../.github/workflows/native-crypto.yml) 自动执行这组 Linux 验证。
