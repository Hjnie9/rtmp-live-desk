# The Windows native package from media_kit is distributed under its MIT license.
# The package layout is shared with media_kit_video 2.0.1.
cmake_minimum_required(VERSION 3.14)
project(media_kit_libs_windows_video LANGUAGES CXX)

function(unpack_runtime url archive_name hash directory required_file)
  set(archive "${CMAKE_BINARY_DIR}/${archive_name}")
  file(DOWNLOAD "${url}/${archive_name}" "${archive}"
    EXPECTED_HASH "SHA256=${hash}" TLS_VERIFY ON TIMEOUT 180)
  if(NOT EXISTS "${directory}/.archive-${hash}" OR NOT EXISTS "${directory}/${required_file}")
    file(MAKE_DIRECTORY "${directory}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
      WORKING_DIRECTORY "${directory}" RESULT_VARIABLE result)
    if(NOT result STREQUAL "0" OR NOT EXISTS "${directory}/${required_file}")
      message(FATAL_ERROR "Could not extract ${archive_name}")
    endif()
    file(WRITE "${directory}/.archive-${hash}" "")
  endif()
endfunction()

set(mpv "${CMAKE_BINARY_DIR}/libmpv")
set(angle "${CMAKE_BINARY_DIR}/ANGLE")
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  unpack_runtime("https://github.com/Carapacik/libmpv-win32-video-cmake/releases/download/20261031"
    "mpv-dev-aarch64-20261031-git-41f6a64506.7z"
    "497841ee27697d816ff3aa14a0e1cce0ce639b593d28b53fb4e06e4410c37df6"
    "${mpv}" "libmpv-2.dll")
  unpack_runtime("https://github.com/Carapacik/flutter-windows-ANGLE-OpenGL-ES/releases/download/v8078"
    "ANGLE-9fe55a5-windows-arm64.7z"
    "f2a2acd39f9d989717d6b6c308230ca0f9f0f2ff4ca082f75836957c4283589b"
    "${angle}" "lib/libEGL.dll")
  set(angle_runtime "${angle}/lib")
  set(angle_extra "${angle_runtime}/vk_swiftshader_icd.json")
else()
  unpack_runtime("https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24"
    "mpv-dev-x86_64-20230924-git-652a1dd.7z"
    "dce982222d7a23e4a1c6f0fb6cc39f6e899a6714624b95ea49cff6558ee97572"
    "${mpv}" "libmpv-2.dll")
  unpack_runtime("https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1"
    "ANGLE.7z"
    "cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a"
    "${angle}" "libEGL.dll")
  set(angle_runtime "${angle}")
  set(angle_extra "${angle_runtime}/zlib.dll")
endif()

# media_kit_video 2.0.1 uses flat libmpv headers and ANGLE import libraries in lib/.
file(COPY "${mpv}/include/mpv/" DESTINATION "${mpv}/include")
set(MEDIA_KIT_LIBS_AVAILABLE TRUE CACHE INTERNAL "Windows playback libraries are available")

set(plugin "media_kit_libs_windows_video_plugin")
add_library(${plugin} SHARED "media_kit_libs_windows_video_plugin_c_api.cpp")
apply_standard_settings(${plugin})
set_target_properties(${plugin} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${plugin} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${plugin} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${plugin} PRIVATE flutter flutter_wrapper_plugin)

set(media_kit_libs_windows_video_bundled_libraries
  "${mpv}/libmpv-2.dll"
  "${angle_runtime}/d3dcompiler_47.dll"
  "${angle_runtime}/libEGL.dll"
  "${angle_runtime}/libGLESv2.dll"
  "${angle_runtime}/vk_swiftshader.dll"
  "${angle_runtime}/vulkan-1.dll"
  ${angle_extra}
  PARENT_SCOPE)
