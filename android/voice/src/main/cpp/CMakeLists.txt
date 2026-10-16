# espeak-ng at piper1-gpl's commit 724808c with the options every snepssen
# voice was trained through (voice-core's scripts/build-espeak.sh): only the
# library and ucd, the dictionaries come from voice-core's data.
cmake_minimum_required(VERSION 3.28)
project(voicecore C CXX)
include(FetchContent)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
foreach(option USE_ASYNC USE_MBROLA USE_LIBSONIC USE_LIBPCAUDIO USE_KLATT USE_SPEECHPLAYER COMPILE_INTONATIONS ENABLE_TESTS)
  set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
set(EXTRA_cmn ON CACHE BOOL "" FORCE)
set(EXTRA_ru ON CACHE BOOL "" FORCE)
add_compile_definitions(_FILE_OFFSET_BITS=64)

FetchContent_Declare(espeakng
  GIT_REPOSITORY https://github.com/espeak-ng/espeak-ng.git
  GIT_TAG 724808c5a83f9ef95fdd0db886ba7ba537ff224a
  EXCLUDE_FROM_ALL)
FetchContent_MakeAvailable(espeakng)

add_library(voicecore SHARED voice_jni.cpp)
target_include_directories(voicecore PRIVATE ${espeakng_SOURCE_DIR}/src/include)
target_link_libraries(voicecore PRIVATE espeak-ng log)
