cmake_minimum_required(VERSION 3.10)
project(native_core LANGUAGES CXX)

option(MAXIMA_WITH_PJSIP "Link the native core against an installed PJSIP library" OFF)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Position-independent code is required for shared objects on ELF platforms
# and is harmless elsewhere.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# native_core builds on every target: Android produces libnative_core.so,
# Windows produces native_core.dll, macOS libnative_core.dylib and Linux
# libnative_core.so. All maxima_* symbols are exported through the
# MAXIMA_EXPORT macro, which maps to __declspec(dllexport) on MSVC and
# default visibility elsewhere.
add_library(native_core SHARED native_core.cpp sip_bridge.cpp)
set_target_properties(native_core PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    OUTPUT_NAME native_core
)

if(ANDROID)
    target_link_libraries(native_core android log)
endif()

if(MSVC)
    target_compile_options(native_core PRIVATE /W4 /O2)
else()
    target_compile_options(native_core PRIVATE -Wall -Wextra -O2)
endif()

if(MAXIMA_WITH_PJSIP)
    # pjsua-lib is the C API. Set PJSIP_ROOT to a build tree produced by
    # tools/build_pjsip.sh; headers live under $PJSIP_ROOT/include and the
    # libraries under $PJSIP_ROOT/lib.
    if(DEFINED PJSIP_ROOT)
        target_include_directories(native_core PRIVATE "${PJSIP_ROOT}/include")
        list(APPEND CMAKE_LIBRARY_PATH "${PJSIP_ROOT}/lib")
    endif()
    find_library(PJSIP_LIBRARY NAMES pjsua pjsip pjsua2)
    if(NOT PJSIP_LIBRARY)
        message(FATAL_ERROR "MAXIMA_WITH_PJSIP=ON requires an installed pjsua library")
    endif()
    target_compile_definitions(native_core PRIVATE MAXIMA_WITH_PJSIP=1)
    target_link_libraries(native_core ${PJSIP_LIBRARY})
endif()

install(TARGETS native_core
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
