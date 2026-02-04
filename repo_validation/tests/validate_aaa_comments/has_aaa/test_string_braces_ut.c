// Copyright (c) Microsoft. All rights reserved.
// Test file with string literals containing braces
// This tests that the function body extraction properly skips string literals

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_string_braces_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test with string literal containing braces - simulates JSON or struct formatting
TEST_FUNCTION(test_with_json_string)
{
    // arrange
    const char* json = "{ \"name\": \"value\", \"count\": 42 }";
    const char* expected = "{ \"name\": \"value\", \"count\": 42 }";

    // act
    int result = strcmp(json, expected);

    // assert
    ASSERT_ARE_EQUAL(int, 0, result);
}

// Test with multiple string literals containing braces
TEST_FUNCTION(test_with_multiple_brace_strings)
{
    // arrange
    const char* open = "{";
    const char* close = "}";
    const char* nested = "{ { inner } }";
    char buffer[100];

    // act
    sprintf(buffer, "%s content %s", open, close);

    // assert
    ASSERT_IS_NOT_NULL(buffer);
    ASSERT_IS_NOT_NULL(nested);
}

// Test with format string containing braces (like printf format for structs)
TEST_FUNCTION(test_with_format_string_braces)
{
    // arrange
    const char* format = "(STRUCT){ .field1 = %d, .field2 = %s }";
    char result[200];

    // act
    sprintf(result, format, 42, "test");

    // assert
    ASSERT_IS_NOT_NULL(result);
}

// Test with compound literal syntax in string (documentation/logging)
TEST_FUNCTION(test_with_compound_literal_string)
{
    // arrange
    const char* log_format = "Created object: { .id = %u, .name = %s, .data = { .x = %d, .y = %d } }";
    
    // act
    size_t len = strlen(log_format);

    // assert
    ASSERT_IS_TRUE(len > 0);
}

// Test with escaped quotes and braces in strings
TEST_FUNCTION(test_with_escaped_content)
{
    // arrange
    const char* complex = "outer { \"nested\": \"value with \\\"quotes\\\"\" }";
    
    // act
    const char* found = strchr(complex, '{');

    // assert
    ASSERT_IS_NOT_NULL(found);
}

// Test with char literals containing braces (edge case)
TEST_FUNCTION(test_with_char_literals)
{
    // arrange
    char open_brace = '{';
    char close_brace = '}';
    
    // act
    int diff = close_brace - open_brace;

    // assert
    ASSERT_ARE_EQUAL(int, 2, diff);
}

// Test with unmatched closing brace in string (edge case)
TEST_FUNCTION(test_with_unmatched_close_brace_string)
{
    // arrange
    const char* message = "Error: unexpected }";
    const char* another = "Missing opening brace: } here";
    
    // act
    size_t len = strlen(message) + strlen(another);

    // assert
    ASSERT_IS_TRUE(len > 0);
}

// Test with unmatched opening brace in string (edge case)
TEST_FUNCTION(test_with_unmatched_open_brace_string)
{
    // arrange
    const char* message = "Error: unclosed {";
    const char* another = "Function call: func(arg {";
    
    // act
    size_t len = strlen(message) + strlen(another);

    // assert
    ASSERT_IS_TRUE(len > 0);
}

END_TEST_SUITE(test_string_braces_ut)
