# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Helper invoked at build time (via `cmake -P`) to compile repo_validator_rs with cargo in a way
# that works regardless of which Rust toolchain manager is installed.
#
# Why this exists:
#   rust-toolchain.toml pins the upstream `stable` channel. That builds fine with public `rustup`,
#   but Microsoft-internal machines use `msrustup`, which only accepts `ms-*` toolchain names and
#   rejects `stable` with `US.no_ms_prefix` ("Toolchain name must start with 'ms-'"). This helper
#   makes the default `cmake --build ... --target <project>_repo_validation` "just work" in all
#   cases, and fail with actionable instructions when no usable toolchain is available.
#
# Required -D arguments:
#   CARGO_MANIFEST    - absolute path to Cargo.toml
#   CARGO_BUILD_FLAGS - extra cargo flags (e.g. "--release"), may be empty
#   RUST_SRC_DIR      - working directory for the cargo invocation
#
# Strategy:
#   * If `msrustup` is on PATH, the active cargo is (almost certainly) the msrustup multiplexer,
#     so try the internal `ms-prod` toolchain first, then fall back to the pinned channel.
#   * Otherwise (public `rustup`), use the pinned channel directly.
#   * If every attempt fails, abort with instructions for both the public and internal setups.

separate_arguments(_cargo_flags NATIVE_COMMAND "${CARGO_BUILD_FLAGS}")

# Runs `cargo [+<toolchain>] build ...`. Pass the sentinel "default" to use the toolchain pinned in
# rust-toolchain.toml (no `+toolchain` override). Sets <result_var> to the cargo exit code.
function(_run_cargo _toolchain _result_var)
    if(_toolchain STREQUAL "default")
        set(_tc_arg "")
    else()
        set(_tc_arg "+${_toolchain}")
    endif()
    execute_process(
        COMMAND cargo ${_tc_arg} build --manifest-path "${CARGO_MANIFEST}" ${_cargo_flags}
        WORKING_DIRECTORY "${RUST_SRC_DIR}"
        RESULT_VARIABLE _rc
    )
    set(${_result_var} "${_rc}" PARENT_SCOPE)
endfunction()

find_program(_MSRUSTUP msrustup)
if(_MSRUSTUP)
    # Internal machine: prefer the supported internal toolchain, fall back to the pinned channel
    # (handles the rare case where a public `rustup` cargo is actually the one on PATH).
    set(_toolchain_order "ms-prod" "default")
else()
    set(_toolchain_order "default")
endif()

set(_built FALSE)
foreach(_toolchain IN LISTS _toolchain_order)
    if(_toolchain STREQUAL "default")
        message(STATUS "repo_validator_rs: building with the toolchain pinned in rust-toolchain.toml")
    else()
        message(STATUS "repo_validator_rs: building with msrustup toolchain '${_toolchain}'")
    endif()
    _run_cargo("${_toolchain}" _rc)
    if(_rc EQUAL 0)
        set(_built TRUE)
        break()
    endif()
endforeach()

if(NOT _built)
    if(_MSRUSTUP)
        message(FATAL_ERROR
            "Failed to build repo_validator_rs.\n"
            "msrustup is installed but neither 'ms-prod' nor the pinned channel produced a build.\n"
            "Install the supported internal toolchain and retry:\n"
            "    msrustup toolchain install ms-prod\n"
            "Then re-run the build. See deps/c-build-tools/repo_validation/README.md.")
    else()
        message(FATAL_ERROR
            "Failed to build repo_validator_rs: no usable Rust toolchain found.\n"
            "Public / upstream machines: install rustup (https://rustup.rs) so the 'stable' channel\n"
            "pinned in rust-toolchain.toml is available.\n"
            "Microsoft-internal machines: install msrustup and the supported toolchain:\n"
            "    msrustup toolchain install ms-prod\n"
            "See deps/c-build-tools/repo_validation/README.md.")
    endif()
endif()
