#include <cstdint>
#include <cstdio>
#include <string>

#include <napi/native_api.h>

#include "native_window/external_window.h"

namespace {

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

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"getSurfaceId", nullptr, GetSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
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