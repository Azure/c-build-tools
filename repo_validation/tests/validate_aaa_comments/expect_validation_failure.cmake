# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

if(NOT DEFINED REPO_VALIDATOR_RS_EXE)
    message(FATAL_ERROR "REPO_VALIDATOR_RS_EXE must be specified")
endif()

if(NOT DEFINED REPO_ROOT)
    message(FATAL_ERROR "REPO_ROOT must be specified")
endif()

execute_process(
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${REPO_ROOT}" --check aaa_comments
    RESULT_VARIABLE VALIDATION_RESULT
    OUTPUT_VARIABLE VALIDATION_OUTPUT
    ERROR_VARIABLE VALIDATION_ERROR
)

message(STATUS "${VALIDATION_OUTPUT}")

if(VALIDATION_ERROR)
    message(STATUS "${VALIDATION_ERROR}")
endif()

if(NOT VALIDATION_RESULT EQUAL 1)
    message(FATAL_ERROR "aaa_comments validation should exit with code 1 for invalid fixture ${REPO_ROOT}, but exited with ${VALIDATION_RESULT}")
endif()

message(STATUS "aaa_comments validation failed as expected for invalid fixture: ${REPO_ROOT}")
