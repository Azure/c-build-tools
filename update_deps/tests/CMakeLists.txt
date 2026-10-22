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

# End-to-end tests (e2e/): propagations run against local fake Azure DevOps, GitHub, Azure CLI and
# git services. The same scenarios pass against the scripts the merged version replaced: the
# Azure-MessagingStore copy for -Pipeline runs, and the c-build-tools version before the merge for
# interactive runs; see dependency_updates_propagation.md. Each test runs its scenarios in parallel
# (interactive ones with Windows PowerShell and, when installed, PowerShell 7). They do not depend on
# the build flavor, so they run only for Debug. A run times out after 1500 seconds; the test
# timeouts leave room for the runner to report a run that hangs.
add_test(NAME update_deps_pipeline_e2e_test
    CONFIGURATIONS Debug
    COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/e2e/test_e2e.ps1" -Kind pipeline -WorkRoot "${CMAKE_CURRENT_BINARY_DIR}/e2e"
)
set_tests_properties(update_deps_pipeline_e2e_test PROPERTIES TIMEOUT 3600)

add_test(NAME update_deps_interactive_e2e_test
    CONFIGURATIONS Debug
    COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/e2e/test_e2e.ps1" -Kind interactive -WorkRoot "${CMAKE_CURRENT_BINARY_DIR}/e2e_interactive"
)
set_tests_properties(update_deps_interactive_e2e_test PROPERTIES TIMEOUT 3600)
