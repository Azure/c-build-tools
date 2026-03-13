# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Requirements Naming Validation Tests
#
# Tests the repo_validator requirements_naming check to ensure it correctly detects
# improperly named requirement documents and validates the fix functionality.
#

# Test 1: Verify tool detects incorrectly named requirements
add_custom_target(test_validate_requirements_naming_detection
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/incorrect_naming" --check requirements_naming
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming detection on incorrectly named files"
    DEPENDS repo_validator
)

# Test 2: Verify tool passes on correctly named requirements
add_custom_target(test_validate_requirements_naming_clean
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/correct_naming" --check requirements_naming
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming validation on correctly named files"
    DEPENDS repo_validator
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_requirements_naming_fix
    # Clean and create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/incorrect_naming" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check requirements_naming --fix
    # Verify files were renamed correctly (tool should pass now)
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check requirements_naming
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing requirements naming fix functionality"
    DEPENDS repo_validator
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