# native/ext — C++ GDExtension(s) for 1차선 참교육 (NATIVE_PORT 3-1, 3-2).
#
#   Linux (container):  bash tools/godot/build_ext.sh            # fetches pinned godot-cpp, builds, checks
#   by hand:            cmake -S native/ext -B native/ext/build/template_debug -G Ninja \
#                             -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_debug
#                       cmake --build native/ext/build/template_debug -j4
#   iOS / Android:      see native/ext/README.md (Mac builds the iOS xcframework).
#
# Output: native/ext/bin/libtraffic.<platform>.<target>.<arch>.so (godot-cpp suffix convention),
#         which native/ext/traffic.gdextension maps per feature tag.
cmake_minimum_required(VERSION 3.17)

# Pins (keep in sync with tools/godot/build_ext.sh and native/ext/README.md).
set(LANE1_GODOT_API_VERSION "4.7" CACHE STRING "Godot API the extension targets (godot-cpp api_version)")
set(GODOTCPP_API_VERSION "${LANE1_GODOT_API_VERSION}" CACHE STRING "" FORCE)
set(LANE1_GODOT_CPP_REF "10.0.0-stable" CACHE STRING "godot-cpp tag the checkout must match (informational)")
set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp" CACHE PATH "godot-cpp checkout (${LANE1_GODOT_CPP_REF})")
# Treat godot-cpp (and its generated bindings) as system headers so our -Wall -Wextra stays readable.
set(GODOTCPP_SYSTEM_HEADERS ON CACHE BOOL "" FORCE)

project(lane1_ext LANGUAGES CXX)

if(NOT EXISTS "${GODOT_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp not found at ${GODOT_CPP_DIR}. Run tools/godot/build_ext.sh (fetches the pinned SHA).")
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_subdirectory("${GODOT_CPP_DIR}" godot-cpp)

set(LANE1_EXT_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/bin")

# ---------------------------------------------------------------------------------------------
# traffic: C++ traffic core (Rng32, LaneEntity, NpcCar, Traffic, NPC MultiMesh writes — M1a).
# iOS links extensions statically into the app (xcframework of .a + godot-cpp xcframework, see
# [dependencies] in traffic.gdextension); every other platform loads a shared library.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_library(traffic STATIC)
else()
    add_library(traffic SHARED)
endif()
target_sources(
    traffic
    PRIVATE
        traffic/src/register_types.cpp
        traffic/src/traffic.cpp
        traffic/src/traffic_core.cpp
        traffic/src/json_exact.cpp
)
target_include_directories(traffic PRIVATE traffic/src)
target_compile_definitions(
    traffic
    PRIVATE
        LANE1_GODOT_API_VERSION="${LANE1_GODOT_API_VERSION}"
        LANE1_GODOT_CPP_VERSION="${LANE1_GODOT_CPP_REF}"
)
target_link_libraries(traffic PRIVATE godot-cpp)

get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)

set_target_properties(
    traffic
    PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        POSITION_INDEPENDENT_CODE ON
        PREFIX "lib"
        OUTPUT_NAME "traffic${GODOTCPP_SUFFIX}"
        LIBRARY_OUTPUT_DIRECTORY "$<1:${LANE1_EXT_BIN_DIR}>"
        RUNTIME_OUTPUT_DIRECTORY "$<1:${LANE1_EXT_BIN_DIR}>"
        ARCHIVE_OUTPUT_DIRECTORY "$<1:${LANE1_EXT_BIN_DIR}>"
)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    # macOS editor on the Mac: Godot loads lib<name>.macos.<target>.framework/lib<name>.macos.<target>
    get_target_property(GODOTCPP_TARGET_NAME godot-cpp GODOTCPP_TARGET)
    set_target_properties(
        traffic
        PROPERTIES
            OUTPUT_NAME "traffic.macos.${GODOTCPP_TARGET_NAME}"
            SUFFIX ""
            LIBRARY_OUTPUT_DIRECTORY "$<1:${LANE1_EXT_BIN_DIR}/libtraffic.macos.${GODOTCPP_TARGET_NAME}.framework>"
    )
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(traffic PRIVATE -Wall -Wextra -Wpedantic)
    # Bit-exact parity with the JS goldens (traffic_core.cpp): no FMA contraction (arm64 clang contracts
    # a*b+c by default), no fast-math reassociation. x86-64 without -mfma never fuses, the phones would.
    target_compile_options(traffic PRIVATE -ffp-contract=off -fno-fast-math)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # The container's Godot is a Nix build (glibc 2.42 closure, no libstdc++ on its search path):
    # libstdc++/libgcc must be linked statically so only libc/libm are resolved at dlopen time.
    target_link_options(traffic PRIVATE -static-libstdc++ -static-libgcc -Wl,--no-undefined)
endif()
