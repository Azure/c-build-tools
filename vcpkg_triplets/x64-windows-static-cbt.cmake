set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_PLATFORM_TOOLSET v143)
# Unfortunately we have to workaround an issue introduced in Visual Studio 17.10 where due to a change in mutex a break in the ABI seems to exist
# https://github.com/microsoft/STL/releases/tag/vs-2022-17.10
# Fixed mutex's constructor to be constexpr. #3824 #4000 #4339
# Note: Programs that aren't following the documented restrictions on binary compatibility may encounter null dereferences in mutex machinery. You must follow this rule:
# When you mix binaries built by different supported versions of the toolset, the Redistributable version must be at least as new as the latest toolset used by any app component.
# You can define _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR as an escape hatch.
set(VCPKG_CXX_FLAGS /guard:cf /D_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
set(VCPKG_C_FLAGS /guard:cf)
set(VCPKG_LINKER_FLAGS /guard:cf)
