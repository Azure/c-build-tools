# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Tests for the dependency propagation scripts (update_deps/propagate_updates.ps1 and its helpers).
# Remote services are mocked and git runs only against local temporary repositories.

# -Pipeline runs under Windows PowerShell 5.1, so that variant always runs.
add_test(NAME update_deps_propagation_test
    COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/test_propagate_updates.ps1"
)
set_tests_properties(update_deps_propagation_test PROPERTIES TIMEOUT 600)

# Interactive runs commonly use PowerShell 7; cover it too when it is installed.
find_program(PWSH_EXECUTABLE pwsh)
if(PWSH_EXECUTABLE)
    add_test(NAME update_deps_propagation_pwsh_test
        COMMAND "${PWSH_EXECUTABLE}" -NoProfile -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/test_propagate_updates.ps1"
    )
    set_tests_properties(update_deps_propagation_pwsh_test PROPERTIES TIMEOUT 600)
endif()
