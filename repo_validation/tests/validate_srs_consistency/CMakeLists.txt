# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Consistency Validation Tests
#
# Tests the validate_srs_consistency.ps1 script to ensure it correctly detects
# inconsistencies between markdown requirements and C code SRS tags.
#

set(VALIDATE_SRS_CONSISTENCY_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_srs_consistency.ps1")

# Test 1: Verify script detects inconsistent SRS tags
add_custom_target(test_validate_srs_consistency_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency detection on inconsistent files"
)

# Test 2: Verify script passes on consistent SRS tags
add_custom_target(test_validate_srs_consistency_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/consistent"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency validation on consistent files"
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_srs_consistency_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify SRS tags were made consistent (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency fix functionality"
)

# Master target for all SRS consistency validation tests
add_custom_target(test_validate_srs_consistency
    COMMENT "Running all SRS consistency validation tests"
)

# Add dependencies - clean test should pass, fix test validates fix functionality
add_dependencies(test_validate_srs_consistency 
    test_validate_srs_consistency_clean
    test_validate_srs_consistency_fix
)

# Note: We don't add test_validate_srs_consistency_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.