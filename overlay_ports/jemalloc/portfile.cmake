# Overlay port for jemalloc.
#
# This is a copy of the upstream vcpkg jemalloc port with one additional change in
# preprocessor.patch: it defines JEMALLOC_LEGACY_WINDOWS_SUPPORT for the MSVC build.
#
# jemalloc 5.3.1 ("Optimize thread-local storage implementation on Windows") made the
# default MSVC thread-specific-data path use __declspec(thread) static TLS instead of the
# dynamic TlsAlloc/TlsGetValue path used through 5.3.0 (see include/jemalloc/internal/tsd_win.h).
# __declspec(thread) static TLS is not reliably available on threads that already exist when a
# module is loaded, so when jemalloc is statically linked into a dynamically-loaded DLL (as it is
# here, together with Detours-based heap interception), pre-existing threads read an uninitialized
# TLS slot and crash deterministically on their first allocation. Defining
# JEMALLOC_LEGACY_WINDOWS_SUPPORT restores the robust TlsAlloc-based dynamic TSD path.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO jemalloc/jemalloc
    REF ${VERSION}
    SHA512 603fd74ad66bbefc40764312b50a72646c317e678beed4201a52b8c2caeae4f08fc4f88310491c72acde9128122e442bd3089c54e29f4294622554703fc92349
    HEAD_REF master
    PATCHES
        fix-configure-ac.patch
        preprocessor.patch
)
if(VCPKG_TARGET_IS_WINDOWS)
    set(opts "ac_cv_search_log=none required" "--without-private-namespace")
endif()

vcpkg_make_configure(
    AUTORECONF
    SOURCE_PATH "${SOURCE_PATH}"
    DISABLE_MSVC_WRAPPERS
    DISABLE_MSVC_TRANSFORMATIONS
    OPTIONS ${opts}
)

vcpkg_make_install()

if(VCPKG_TARGET_IS_WINDOWS)
    file(COPY "${SOURCE_PATH}/include/msvc_compat/strings.h" DESTINATION "${CURRENT_PACKAGES_DIR}/include/jemalloc/msvc_compat")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/jemalloc/jemalloc.h" "<strings.h>" "\"msvc_compat/strings.h\"")
    if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
        file(COPY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-rel/lib/jemalloc.lib" DESTINATION "${CURRENT_PACKAGES_DIR}/lib")
        file(MAKE_DIRECTORY "${CURRENT_PACKAGES_DIR}/bin")
        file(RENAME "${CURRENT_PACKAGES_DIR}/lib/jemalloc.dll" "${CURRENT_PACKAGES_DIR}/bin/jemalloc.dll")
    endif()
    if(NOT VCPKG_BUILD_TYPE)
        if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
            file(COPY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-dbg/lib/jemalloc.lib" DESTINATION "${CURRENT_PACKAGES_DIR}/debug/lib")
            file(MAKE_DIRECTORY "${CURRENT_PACKAGES_DIR}/debug/bin")
            file(RENAME "${CURRENT_PACKAGES_DIR}/debug/lib/jemalloc.dll" "${CURRENT_PACKAGES_DIR}/debug/bin/jemalloc.dll")
        endif()
    endif()
    if(VCPKG_LIBRARY_LINKAGE STREQUAL "static")
        vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/jemalloc.pc" "install_suffix=" "install_suffix=_s")
        if(NOT VCPKG_BUILD_TYPE)
            vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/jemalloc.pc" "install_suffix=" "install_suffix=_s")
        endif()
    endif()
endif()

vcpkg_fixup_pkgconfig()

vcpkg_copy_pdbs()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/tools")

# Handle copyright
file(INSTALL "${SOURCE_PATH}/COPYING" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}" RENAME copyright)
