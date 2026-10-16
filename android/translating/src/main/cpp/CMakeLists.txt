# llama.cpp at release v0.7.0, with the options of its own Android app
# (examples/llama.android): shared libraries, every CPU variant built and the
# best chosen at run time, Arm's KleidiAI kernels, nothing but the library.
cmake_minimum_required(VERSION 3.28)
project(translator C CXX)
set(CMAKE_CXX_STANDARD 17)
include(FetchContent)

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
foreach(option LLAMA_BUILD_TESTS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_TOOLS LLAMA_BUILD_SERVER LLAMA_BUILD_COMMON
               LLAMA_BUILD_APP LLAMA_OPENSSL LLAMA_CURL GGML_NATIVE GGML_LLAMAFILE)
  set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
foreach(option GGML_BACKEND_DL GGML_CPU_ALL_VARIANTS GGML_CPU_KLEIDIAI GGML_OPENMP)
  set(${option} ON CACHE BOOL "" FORCE)
endforeach()

FetchContent_Declare(llama
  GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
  GIT_TAG 620d2225cc436ab0b001e3200e590e3b286ef9ab)
FetchContent_MakeAvailable(llama)

add_library(translator SHARED translator_jni.cpp)
target_link_libraries(translator PRIVATE llama ggml log)
