# Test Module Requirements

This file contains requirements to test the script's handling of malformed C comments (SRS tags missing the closing ] bracket).

## Requirements

**SRS_MALFORMED_TEST_01_001: [** test_module_create shall allocate memory for a test module. **]**

**SRS_MALFORMED_TEST_01_002: [** test_module_create shall return NULL if allocation fails. **]**

**SRS_MALFORMED_TEST_01_003: [** test_module_destroy shall free all allocated memory. **]**
