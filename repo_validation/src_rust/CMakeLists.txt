#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

cmake_minimum_required(VERSION 3.18)

# Build the Rust repo_validator_rs executable via cargo
# Uses ms-prod-1.93 toolchain pinned in rust-toolchain.toml

set(RUST_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(RUST_MANIFEST "${RUST_SRC_DIR}/Cargo.toml")

# Determine cargo build profile and output directory
if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo" OR CMAKE_BUILD_TYPE STREQUAL "MinSizeRel")
    set(CARGO_BUILD_FLAGS "--release")
    set(CARGO_PROFILE "release")
else()
    set(CARGO_BUILD_FLAGS "")
    set(CARGO_PROFILE "debug")
endif()

# For multi-config generators (Visual Studio), default to release
if(CMAKE_CONFIGURATION_TYPES)
    set(CARGO_BUILD_FLAGS "--release")
    set(CARGO_PROFILE "release")
endif()

if(WIN32)
    set(RUST_EXE_NAME "repo_validator_rs.exe")
else()
    set(RUST_EXE_NAME "repo_validator_rs")
endif()

set(RUST_EXE_PATH "${RUST_SRC_DIR}/target/${CARGO_PROFILE}/${RUST_EXE_NAME}")

# Custom target to build the Rust binary
# The stamp file ensures cargo is only re-invoked when sources change
add_custom_command(
    OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/repo_validator_rs.stamp"
    COMMAND cargo build --manifest-path "${RUST_MANIFEST}" ${CARGO_BUILD_FLAGS}
    COMMAND ${CMAKE_COMMAND} -E touch "${CMAKE_CURRENT_BINARY_DIR}/repo_validator_rs.stamp"
    WORKING_DIRECTORY "${RUST_SRC_DIR}"
    COMMENT "Building Rust repo_validator_rs via cargo"
    DEPENDS
        "${RUST_MANIFEST}"
        "${RUST_SRC_DIR}/src/main.rs"
        "${RUST_SRC_DIR}/src/config.rs"
        "${RUST_SRC_DIR}/src/file_walker.rs"
        "${RUST_SRC_DIR}/src/checks/mod.rs"
        "${RUST_SRC_DIR}/src/checks/no_tabs.rs"
        "${RUST_SRC_DIR}/src/checks/file_endings.rs"
        "${RUST_SRC_DIR}/src/checks/requirements_naming.rs"
        "${RUST_SRC_DIR}/src/checks/srs_uniqueness.rs"
        "${RUST_SRC_DIR}/src/checks/enable_mocks.rs"
        "${RUST_SRC_DIR}/src/checks/no_vld_include.rs"
        "${RUST_SRC_DIR}/src/checks/no_backticks_in_srs.rs"
        "${RUST_SRC_DIR}/src/checks/test_spec_tags.rs"
)

add_custom_target(repo_validator_rs
    DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/repo_validator_rs.stamp"
)

# Export the executable path for use by test targets
set(REPO_VALIDATOR_RS_EXE "${RUST_EXE_PATH}" PARENT_SCOPE)
