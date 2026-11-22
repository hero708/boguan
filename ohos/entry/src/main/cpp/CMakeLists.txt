# NAPI bridge between the ArkTS player plugin and the platform graphics stack.
#
# Flutter hands the plugin an OHNativeWindow* for its external texture, while
# AVPlayer only accepts a surface id string, so this module exposes
# getSurfaceId(pointer) built on OH_NativeWindow_GetSurfaceId.
cmake_minimum_required(VERSION 3.5.0)
project(fq_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(fq_native SHARED fq_native.cpp)

# libc++ is linked statically: the device image has no libc++_shared.so, and a
# NEEDED entry for it would make dlopen fail at runtime.
target_link_options(fq_native PRIVATE -static-libstdc++)

target_link_libraries(fq_native PUBLIC libace_napi.z.so libnative_window.so)