#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <dlfcn.h>
#include <napi/native_api.h>

#include "native_window/external_window.h"

namespace {

using MediaOpenFn = char *(*)(const char *request);
using MediaCloseFn = void (*)(const char *id);
using MediaFreeFn = void (*)(char *response);

const char *const kBridgeMissing = "media bridge unavailable: libfqapi_core.so is not loaded";

/**
 * Looks a Rust-core symbol up in the process image first: Flutter loads
 * libfqapi_core.so by name for flutter_rust_bridge, so it is already mapped
 * before the player plugin runs. The explicit dlopen keeps the lookup working
 * when the load order changes (or when the engine is pre-warmed).
 */
void *ResolveMediaSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != nullptr) {
        return symbol;
    }
    static void *handle = nullptr;
    static bool opened = false;
    if (!opened) {
        opened = true;
        handle = dlopen("libfqapi_core.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        return nullptr;
    }
    return dlsym(handle, name);
}

std::string ReadStringArg(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return std::string();
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written) != napi_ok) {
        return std::string();
    }
    return std::string(buffer.data(), written);
}

/** Appends a JSON string literal; URLs and hex keys are ASCII but stay escaped. */
void AppendJsonString(std::string &out, const std::string &value) {
    out.push_back('"');
    for (const char raw : value) {
        const unsigned char byte = static_cast<unsigned char>(raw);
        switch (raw) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (byte < 0x20) {
                    char escaped[8];
                    std::snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
                    out += escaped;
                } else {
                    out.push_back(raw);
                }
                break;
        }
    }
    out.push_back('"');
}

/**
 * Converts the native window pointer owned by a Flutter external texture into
 * the surface id string that AVPlayer.surfaceId expects.
 *
 * The Dart side paints the player through a Texture widget; the embedding's
 * TextureRegistry hands the ArkTS plugin an OHNativeWindow* (SurfaceTexture),
 * and AVPlayer can only be pointed at surfaces by id, so the conversion has to
 * happen in native code.
 */
napi_value GetSurfaceId(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (status != napi_ok || argc < 1) {
        napi_throw_error(env, nullptr, "getSurfaceId expects one argument");
        return nullptr;
    }

    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[0], &type);
    void *window = nullptr;
    if (type == napi_bigint) {
        uint64_t raw = 0;
        bool lossless = false;
        napi_get_value_bigint_uint64(env, argv[0], &raw, &lossless);
        window = reinterpret_cast<void *>(static_cast<uintptr_t>(raw));
    } else if (type == napi_number) {
        double raw = 0;
        napi_get_value_double(env, argv[0], &raw);
        window = reinterpret_cast<void *>(static_cast<uintptr_t>(raw));
    } else {
        napi_throw_type_error(env, nullptr, "pointer must be a bigint or number");
        return nullptr;
    }

    if (window == nullptr) {
        napi_throw_error(env, nullptr, "native window pointer is null");
        return nullptr;
    }

    uint64_t surfaceId = 0;
    int32_t result = OH_NativeWindow_GetSurfaceId(reinterpret_cast<OHNativeWindow *>(window), &surfaceId);
    if (result != 0) {
        char message[64];
        std::snprintf(message, sizeof(message), "OH_NativeWindow_GetSurfaceId failed: %d", result);
        napi_throw_error(env, nullptr, message);
        return nullptr;
    }

    napi_value output = nullptr;
    std::string text = std::to_string(surfaceId);
    napi_create_string_utf8(env, text.c_str(), text.size(), &output);
    return output;
}

/**
 * Opens a loopback media session in the Rust core: the core fetches the CDN
 * range requests (signed headers, retries), decrypts CENC in memory and serves
 * clear bytes on http://127.0.0.1:<port>/media/<token>.
 *
 * AVPlayer cannot attach the per-request auth headers the CDN expects, so the
 * ArkTS side always routes playback through this bridge - clear streams
 * included, exactly like the desktop player does.
 *
 * Returns the Rust JSON document: {"id":..., "url":...} or
 * {"error":..., "kind":..., "status":...}.
 */
napi_value OpenMediaSource(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (status != napi_ok || argc < 2) {
        napi_throw_error(env, nullptr, "openMediaSource expects (url, key)");
        return nullptr;
    }

    const std::string url = ReadStringArg(env, argv[0]);
    const std::string key = ReadStringArg(env, argv[1]);
    if (url.empty()) {
        napi_throw_error(env, nullptr, "openMediaSource: empty url");
        return nullptr;
    }

    auto open = reinterpret_cast<MediaOpenFn>(ResolveMediaSymbol("fq_desktop_media_open"));
    auto release = reinterpret_cast<MediaFreeFn>(ResolveMediaSymbol("fq_desktop_media_free"));
    if (open == nullptr || release == nullptr) {
        napi_throw_error(env, nullptr, kBridgeMissing);
        return nullptr;
    }

    std::string request;
    request.reserve(url.size() + key.size() + 32);
    request += "{\"url\":";
    AppendJsonString(request, url);
    request += ",\"key\":";
    AppendJsonString(request, key);
    request += "}";

    char *response = open(request.c_str());
    if (response == nullptr) {
        napi_throw_error(env, nullptr, "media bridge returned no response");
        return nullptr;
    }

    napi_value output = nullptr;
    napi_create_string_utf8(env, response, NAPI_AUTO_LENGTH, &output);
    release(response);
    return output;
}

/** Closes a loopback media session; the token is the "id" field of the open reply. */
napi_value CloseMediaSource(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (status != napi_ok || argc < 1) {
        napi_throw_error(env, nullptr, "closeMediaSource expects (id)");
        return nullptr;
    }
    const std::string id = ReadStringArg(env, argv[0]);
    if (id.empty()) {
        return nullptr;
    }
    auto close = reinterpret_cast<MediaCloseFn>(ResolveMediaSymbol("fq_desktop_media_close"));
    if (close == nullptr) {
        napi_throw_error(env, nullptr, kBridgeMissing);
        return nullptr;
    }
    close(id.c_str());
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"getSurfaceId", nullptr, GetSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openMediaSource", nullptr, OpenMediaSource, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeMediaSource", nullptr, CloseMediaSource, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "fq_native",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

__attribute__((constructor)) static void RegisterFqNativeModule() {
    napi_module_register(&g_module);
}
