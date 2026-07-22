cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "camera_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.24)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

list(APPEND PLUGIN_SOURCES
  "camera_plugin.h"
  "camera_plugin.cpp"
  "camera.h"
  "camera.cpp"
  "capture_controller.h"
  "capture_controller.cpp"
  "capture_controller_listener.h"
  "capture_engine_listener.h"
  "capture_engine_listener.cpp"
  "string_utils.h"
  "string_utils.cpp"
  "capture_device_info.h"
  "capture_device_info.cpp"
  "messages.g.h"
  "messages.g.cpp"
  "preview_handler.h"
  "preview_handler.cpp"
  "record_handler.h"
  "record_handler.cpp"
  "photo_handler.h"
  "photo_handler.cpp"
  "texture_handler.h"
  "texture_handler.cpp"
  "com_heap_ptr.h"
)

add_library(${PLUGIN_NAME} SHARED
  "camera_windows.cpp"
  "include/camera_windows/camera_windows.h"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE mf mfplat mfuuid d3d11)

# List of absolute paths to libraries that should be bundled with the plugin
set(camera_windows_bundled_libraries
  ""
  PARENT_SCOPE
)

# The upstream unit test target is omitted together with the test/
# directory: this vendored copy is only consumed by the app.
