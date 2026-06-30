# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Helper invoked at build time (via `cmake -P`) to compile repo_validator_rs with cargo using the
# machine's default Rust toolchain, with a fallback that configures one if none is set.
#
# Why this exists:
#   This crate intentionally does NOT pin a toolchain via rust-toolchain.toml. Pinning the upstream
#   `stable` channel breaks Microsoft-internal machines, where the active cargo is `msrustup`, which
#   only accepts `ms-*` toolchain names. Without a pin, cargo uses each machine's default toolchain
#   (`stable` on rustup, an `ms-*` toolchain on msrustup), which builds the validator in both cases.
#
#   The one gap is a machine that has `rustup` installed but NO default toolchain configured (some CI
#   agents previously relied solely on the rust-toolchain.toml). There cargo fails with
#   "rustup could not choose a version of cargo to run ... no default is configured". For that case we
#   configure rustup's `stable` as the default and retry. msrustup machines always have a default, so
#   this fallback is never reached there (rustup may not even be installed).
#
# Required -D arguments:
#   CARGO_MANIFEST    - absolute path to Cargo.toml
#   CARGO_BUILD_FLAGS - extra cargo flags (e.g. "--release"), may be empty
#   RUST_SRC_DIR      - working directory for the cargo invocation

separate_arguments(_cargo_flags NATIVE_COMMAND "${CARGO_BUILD_FLAGS}")

function(_cargo_build _result_var)
    execute_process(
        COMMAND cargo build --manifest-path "${CARGO_MANIFEST}" ${_cargo_flags}
        WORKING_DIRECTORY "${RUST_SRC_DIR}"
        RESULT_VARIABLE _rc
    )
    set(${_result_var} "${_rc}" PARENT_SCOPE)
endfunction()

# 1. Build with the machine's default toolchain.
_cargo_build(_rc)
if(_rc EQUAL 0)
    return()
endif()

# 2. Fallback for a rustup machine with no default toolchain configured: set 'stable' as the default
#    and retry. (Never reached on msrustup, which always has a default toolchain.)
find_program(_RUSTUP rustup)
if(_RUSTUP)
    message(STATUS "repo_validator_rs: initial cargo build failed; running 'rustup default stable' and retrying.")
    execute_process(COMMAND "${_RUSTUP}" default stable RESULT_VARIABLE _set_default)
    if(_set_default EQUAL 0)
        _cargo_build(_rc_retry)
        if(_rc_retry EQUAL 0)
            return()
        endif()
    endif()
endif()

message(FATAL_ERROR
    "Failed to build repo_validator_rs.\n"
    "If this is a 'no default toolchain' error, configure a default Rust toolchain and re-run:\n"
    "  - rustup:   rustup default stable\n"
    "  - msrustup: msrustup default ms-prod\n"
    "Otherwise, see the cargo error output above. See deps/c-build-tools/repo_validation/README.md.")
