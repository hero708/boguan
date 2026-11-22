fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    // The CENC crypto core is plain C11 with no platform dependencies; it is
    // compiled on every target that ships the FFI playback path (desktop and
    // HarmonyOS/OpenHarmony). Android compiles it through native/CMakeLists.txt
    // instead, so it is intentionally skipped there.
    let build_crypto = target_os == "windows" || target_os == "linux" || target_os == "ohos";
    if !build_crypto {
        return;
    }
    let sources = [
        "crypto_core/sp_error.c",
        "crypto_core/sp_stream.c",
        "crypto_core/mp4_cenc.c",
        "crypto_core/sp_aes.c",
        "third_party/tiny_aes/aes.c",
    ];
    let mut build = cc::Build::new();
    build
        .include("../native/crypto_core")
        .std("c11")
        .pic(target_os == "linux" || target_os == "ohos")
        .flag_if_supported("/experimental:c11atomics")
        .define("CBC", "0")
        .define("CTR", "0")
        .define("ECB", "1");
    for source in sources {
        let path = format!("../native/{source}");
        println!("cargo:rerun-if-changed={path}");
        build.file(path);
    }
    println!("cargo:rerun-if-changed=../native/crypto_core");
    println!("cargo:rerun-if-changed=../native/third_party/tiny_aes");
    build.compile("sp_crypto_core");
}