````markdown
<!--
TEST CASE: This tests that requirements where the entire text within brackets is bold are handled correctly.
The pattern [** text **] should become just "text" after markdown stripping, not "** text **".
This is a common pattern used for type names in requirements.
-->

# test_module_requirements

## supported_types

```c
void supported_types(void);
```

**SRS_BOLD_TEST_01_001: [** The following types shall be supported: **]**
-	**SRS_BOLD_TEST_01_002: [** unsigned char **]**
-	**SRS_BOLD_TEST_01_003: [** short **]**
-	**SRS_BOLD_TEST_01_004: [** unsigned short **]**
-	**SRS_BOLD_TEST_01_005: [** int **]**
-	**SRS_BOLD_TEST_01_006: [** unsigned int **]**
-	**SRS_BOLD_TEST_01_007: [** long **]**
-	**SRS_BOLD_TEST_01_008: [** unsigned long **]**
-	**SRS_BOLD_TEST_01_009: [** long long **]**
-	**SRS_BOLD_TEST_01_010: [** unsigned long long **]**
-	**SRS_BOLD_TEST_01_011: [** float **]**
-	**SRS_BOLD_TEST_01_012: [** double **]**
-	**SRS_BOLD_TEST_01_013: [** long double **]**
-	**SRS_BOLD_TEST_01_014: [** size_t **]**

````