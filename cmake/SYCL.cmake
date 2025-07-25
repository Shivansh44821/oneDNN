#===============================================================================
# Copyright 2019-2025 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===============================================================================

if(SYCL_cmake_included)
    return()
endif()
set(SYCL_cmake_included true)

include("cmake/host_compiler_id.cmake")

if(NOT DNNL_WITH_SYCL)
    return()
endif()

include(FindPackageHandleStandardArgs)
include("cmake/dpcpp_driver_check.cmake")

# Link SYCL library explicitly for open-source compiler on Windows.
# In other cases, the compiler is able to automatically link it.
if(WIN32 AND CMAKE_BASE_NAME STREQUAL "clang++")
    # TODO: we can drop this workaround once an open-source release
    # for Windows has a fix for the issue.
    foreach(sycl_lib_version 8 7 6 "")
        if(UPPERCASE_CMAKE_BUILD_TYPE STREQUAL "DEBUG")
            set(SYCL_LIBRARY_NAME "sycl${sycl_lib_version}d")
        else()
            set(SYCL_LIBRARY_NAME "sycl${sycl_lib_version}")
        endif()

        find_library(SYCL_LIBRARY ${SYCL_LIBRARY_NAME})

        if(EXISTS "${SYCL_LIBRARY}")
            list(APPEND EXTRA_SHARED_LIBS ${SYCL_LIBRARY})
            set(SYCL_LIBRARY_FOUND TRUE)
            break()
        endif()
    endforeach()
    if(NOT SYCL_LIBRARY_FOUND)
        message(FATAL_ERROR "Cannot find a SYCL library")
    endif()
endif()

# CUDA and ROCm contain OpenCL headers that conflict with the OpenCL
# headers located in the compiler's directory.
# The workaround is to get interface include directories from all CUDA/ROCm
# import targets and lower their priority via `-idirafter` so that the
# compiler picks up the proper OpenCL headers.
macro(adjust_headers_priority targets)
    if(NOT WIN32)
        set(include_dirs)
        foreach(import_target ${targets})
            get_target_property(import_target_include_dirs ${import_target} INTERFACE_INCLUDE_DIRECTORIES)
            set_target_properties(${import_target} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "")
            list(APPEND include_dirs ${import_target_include_dirs})
        endforeach()

        list(REMOVE_DUPLICATES include_dirs)
        foreach(include_dir ${include_dirs})
            append(CMAKE_CXX_FLAGS "-idirafter${include_dir}")
        endforeach()
    endif()
endmacro()

macro(suppress_warnings_for_nvidia_target)
    # XXX: Suppress warning coming from SYCL headers:
    #   error: use of function template name with no prior declaration in
    #   function call with eplicit template arguments is a C++20 extension
    append(CMAKE_CXX_FLAGS "-Wno-c++20-extensions")

    # Suppress LLVM warning about not supporting latest cuda. It's safe enough
    # as long as no new cuda features are used in SYCL kernels.
    append(CMAKE_CXX_FLAGS "-Wno-unknown-cuda-version")
endmacro()

if(DNNL_SYCL_CUDA)
    suppress_warnings_for_nvidia_target()
    find_package(cuBLAS REQUIRED)
    find_package(cublasLt REQUIRED)
    find_package(cuDNN REQUIRED)

    adjust_headers_priority("cuBLAS::cuBLAS;cuDNN::cuDNN;cublasLt::cublasLt")
    add_definitions_with_host_compiler("-DCUDA_NO_HALF")

    list(APPEND EXTRA_SHARED_LIBS cuBLAS::cuBLAS cuDNN::cuDNN cublasLt::cublasLt)
    message(STATUS "DPC++ support is enabled (CUDA)")
elseif(DNNL_SYCL_HIP)
    find_package(HIP REQUIRED)
    find_package(rocBLAS REQUIRED)
    find_package(MIOpen REQUIRED)

    adjust_headers_priority("HIP::HIP;rocBLAS::rocBLAS;MIOpen::MIOpen")
    add_definitions_with_host_compiler("-D__HIP_PLATFORM_AMD__=1")

    list(APPEND EXTRA_SHARED_LIBS HIP::HIP rocBLAS::rocBLAS MIOpen::MIOpen)
    message(STATUS "DPC++ support is enabled (HIP)")
elseif(DNNL_SYCL_GENERIC)
    CHECK_CXX_COMPILER_FLAG("-fsycl -fsycl-targets=nvptx64-nvidia-cuda" NVIDIA_TARGET_SUPPORTED)

    if(NVIDIA_TARGET_SUPPORTED)
        suppress_warnings_for_nvidia_target()
    endif()
else()
    find_library(OPENCL_LIBRARY OpenCL PATHS ENV LIBRARY_PATH ENV LIB NO_DEFAULT_PATH)
    if(OPENCL_LIBRARY)
        message(STATUS "OpenCL runtime is found in the environment: ${OPENCL_LIBRARY}")
        list(APPEND EXTRA_SHARED_LIBS ${OPENCL_LIBRARY})
    else()
        message(STATUS "OpenCL runtime is not found in the environment. Trying to find it using find_package(...)")
        # As a plan B we try to locate OpenCL runtime using our OpenCL CMake module.
        find_package(OpenCL REQUIRED)
        # Unset INTERFACE_INCLUDE_DIRECTORIES property because DPCPP
        # compiler contains OpenCL headers
        set_target_properties(OpenCL::OpenCL PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "")
        list(APPEND EXTRA_SHARED_LIBS OpenCL::OpenCL)
    endif()

    # In order to support large shapes.
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-sycl-id-queries-fit-in-int")
    message(STATUS "DPC++ support is enabled (OpenCL and Level Zero)")
endif()

# XXX: Suppress warning coming from SYCL headers:
#   #pragma message("The Intel extensions have been moved into cl_ext.h.
#   Please include cl_ext.h directly.")
if(NOT WIN32)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-#pragma-messages")
endif()

add_definitions_with_host_compiler("-DCL_TARGET_OPENCL_VERSION=300")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsycl")

if(DNNL_EXPERIMENTAL_SYCL_KERNEL_COMPILER)
    include(CheckCXXSourceRuns)
    set(CHECK_SYCL_KERNEL_COMPILER_SOURCE
    "
        #include <sycl/sycl.hpp>
        namespace syclex = sycl::ext::oneapi::experimental;
        int main() {
            for (auto platform : sycl::platform::get_platforms())
                for (auto d : platform.get_devices())
                    if (!d.ext_oneapi_can_compile(syclex::source_language::opencl))
                        return 1;
            return 0;
        }
    ")
    CHECK_CXX_SOURCE_RUNS(
        "${CHECK_SYCL_KERNEL_COMPILER_SOURCE}"
        SYCL_KERNEL_COMPILER_DETECTED)
    if(NOT SYCL_KERNEL_COMPILER_DETECTED)
        message(FATAL_ERROR
"SYCL implementation does not support OpenCL kernel compiler extension. Make sure that SYCL and OCLOC are correctly installed.")
    endif()
endif()
