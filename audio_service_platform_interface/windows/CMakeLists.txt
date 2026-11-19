# The Flutter tooling requires a version of Visual Studio that includes
# CMake 3.14 or later. Do not raise this version: it would break builds for
# users with older toolchains.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "audio_service_platform_interface")
project(${PROJECT_NAME} LANGUAGES CXX)

# The plugin library name must stay in this form: the Flutter tooling looks
# for `${package_name}_plugin` when it generates the plugin registrant.
set(PLUGIN_NAME "audio_service_platform_interface_plugin")

list(APPEND PLUGIN_SOURCES
  "smtc_audio_service_plugin.cpp"
  "smtc_service.cpp"
)

add_library(${PLUGIN_NAME} SHARED
  "include/audio_service_platform_interface/smtc_audio_service_plugin.h"
  ${PLUGIN_SOURCES}
)

# Standard build settings come from the application-level CMakeLists.txt
# (C++17, /W4 /WX, /EHsc and _HAS_EXCEPTIONS=0).
apply_standard_settings(${PLUGIN_NAME})

# Hide symbols by default; only the C entry point is exported explicitly.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
# windowsapp.lib provides the WinRT activation functions
# (RoGetActivationFactory / RoActivateInstance).
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  windowsapp
)

set(audio_service_platform_interface_bundled_libraries
  ""
  PARENT_SCOPE
)
