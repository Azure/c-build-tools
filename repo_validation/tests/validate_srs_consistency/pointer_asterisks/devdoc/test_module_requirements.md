<!--
TEST CASE: This tests that asterisks in C pointer syntax (e.g., *ptr) are preserved
when they appear inside backticks in markdown requirements.
This was a real bug where requirements like "If `*t1` is `NULL`" would lose the asterisks.
-->

# test_module_requirements

## test_function

```c
int test_function(void** t1, void** t2);
```

**SRS_POINTER_TEST_01_001: [** If `*t1` is `NULL` and `*t2` is not `NULL` then `test_function` shall move `*t2` under `t1`, set `*t2` to `NULL` and return 0. **]**

**SRS_POINTER_TEST_01_002: [** If `*t1` is not `NULL` and `*t2` is `NULL` then `test_function` shall free `*t1`, set `*t1` to `NULL` and return 0. **]**

**SRS_POINTER_TEST_01_003: [** If both `*t1` and `*t2` are `NULL` then `test_function` shall return 0. **]**
