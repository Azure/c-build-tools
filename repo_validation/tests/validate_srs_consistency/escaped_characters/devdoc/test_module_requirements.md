<!--
TEST CASE: This tests that escaped characters in markdown (\<, \>, \\) are properly
unescaped when comparing with C code comments.
Markdown files use backslash escaping to prevent special character interpretation.
The validation script must unescape these when comparing with C code.
-->

# test_module_requirements

## test_function

```c
int test_function(int count);
```

**SRS_ESCAPED_TEST_01_001: [** If `next_available_slot` \< `window_count` then `test_function` shall increment the count. **]**

**SRS_ESCAPED_TEST_01_002: [** If `next_available_slot` \>= `window_count` then `test_function` shall reset to 0. **]**

**SRS_ESCAPED_TEST_01_003: [** The path shall be in format `directory\\filename` for Windows paths. **]**
