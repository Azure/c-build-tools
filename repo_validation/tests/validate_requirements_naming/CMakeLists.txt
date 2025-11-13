# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Requirements Naming Validation Tests
#
# Tests the validate_requirements_naming.ps1 script to ensure it correctly detects
# improperly named requirement documents and validates the fix functionality.
#

set(VALIDATE_REQUIREMENTS_NAMING_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_requirements_naming.ps1")

# Test 1: Verify script detects incorrectly named requirements
add_custom_target(test_validate_requirements_naming_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_REQUIREMENTS_NAMING_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/incorrect_naming"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming detection on incorrectly named files"
)

# Test 2: Verify script passes on correctly named requirements
add_custom_target(test_validate_requirements_naming_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_REQUIREMENTS_NAMING_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/correct_naming"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming validation on correctly named files"
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_requirements_naming_fix
    # Clean and create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/incorrect_naming" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_REQUIREMENTS_NAMING_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify files were renamed correctly (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_REQUIREMENTS_NAMING_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming fix functionality"
)

# Master target for all requirements naming validation tests
add_custom_target(test_validate_requirements_naming
    COMMENT "Running all requirements naming validation tests"
)

# Add dependencies - clean test should pass, fix test validates fix functionality
add_dependencies(test_validate_requirements_naming 
    test_validate_requirements_naming_clean
    test_validate_requirements_naming_fix
)

# Note: We don't add test_validate_requirements_naming_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.