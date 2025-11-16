<!--
TEST CASE: This file is based on constbuffer_array_requirements.md from c-util.
It reproduces a real bug where consecutive requirements (SRS_TESTCASE_REPR_CBA_05_006 and 05_007)
appeaing on consecutive lines in the markdown caused the validation script to corrupt C file
comments by merging requirement text from both markdown lines into a single C comment.
-->

# testcase_repr_cba_requirements
================

## Overview

`testcase_repr_cba` is a module that stiches several `CONSTBUFFER_HANDLE`s together. `testcase_repr_cba` can add/remove a `CONSTBUFFER_HANDLE` at the beginning (front) of the already constructed stitch. `testcase_repr_cba` can merge with another `testcase_repr_cba` by appending the contents of one array to the other.

`testcase_repr_cba_HANDLE`s are immutable, that is, adding/removing a `CONSTBUFFER_HANDLE` to/from an existing `testcase_repr_cba_HANDLE` will result in a new `testcase_repr_cba_HANDLE`.

## Exposed API

```c
typedef struct testcase_repr_cba_HANDLE_DATA_TAG* testcase_repr_cba_HANDLE;

MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create, const CONSTBUFFER_HANDLE*, buffers, uint32_t, buffer_count);
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_with_move_buffers, CONSTBUFFER_HANDLE*, buffers, uint32_t, buffer_count);
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_buffer_index_and_count, testcase_repr_cba_HANDLE, original, uint32_t, start_buffer_index, uint32_t, buffer_count);
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_buffer_offset_and_count, testcase_repr_cba_HANDLE, original, uint32_t, start_buffer_index, uint32_t, buffer_count, uint32_t, start_buffer_offset, uint32_t, end_buffer_size)
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_empty);
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_array_array, const testcase_repr_cba_HANDLE*, buffer_arrays, uint32_t, buffer_array_count);

MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_remove_empty_buffers, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);

MOCKABLE_FUNCTION(, void, testcase_repr_cba_inc_ref, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);
MOCKABLE_FUNCTION(, void, testcase_repr_cba_dec_ref, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);

/*add in front*/
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_add_front, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE, constbuffer_handle);

/*remove front*/
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_remove_front, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE *const_buffer_handle);

/* getters */
MOCKABLE_FUNCTION(, int, testcase_repr_cba_get_buffer_count, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t*, buffer_count);
MOCKABLE_FUNCTION(, CONSTBUFFER_HANDLE, testcase_repr_cba_get_buffer, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t, buffer_index);
MOCKABLE_FUNCTION(, const CONSTBUFFER*, testcase_repr_cba_get_buffer_content, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t, buffer_index);
MOCKABLE_FUNCTION(, int, testcase_repr_cba_get_all_buffers_size, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t*, all_buffers_size);
MOCKABLE_FUNCTION(, const CONSTBUFFER_HANDLE*, testcase_repr_cba_get_const_buffer_handle_array, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);

/*compare*/
MOCKABLE_FUNCTION(, bool, testcase_repr_cba_HANDLE_contain_same, testcase_repr_cba_HANDLE, left, testcase_repr_cba_HANDLE, right);
```

### testcase_repr_cba_create

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create, const CONSTBUFFER_HANDLE*, buffers, uint32_t, buffer_count);
```

`testcase_repr_cba_create` creates a new const buffer array made of the const buffers in `buffers`.

**SRS_TESTCASE_REPR_CBA_01_009: [** `testcase_repr_cba_create` shall allocate memory for a new `testcase_repr_cba_HANDLE` that can hold `buffer_count` buffers. **]**

**SRS_TESTCASE_REPR_CBA_01_010: [** `testcase_repr_cba_create` shall clone the buffers in `buffers` and store them. **]**

**SRS_TESTCASE_REPR_CBA_01_011: [** On success `testcase_repr_cba_create` shall return a non-NULL handle. **]**

**SRS_TESTCASE_REPR_CBA_01_012: [** If `buffers` is NULL and `buffer_count` is not 0, `testcase_repr_cba_create` shall fail and return NULL. **]**

**SRS_TESTCASE_REPR_CBA_01_014: [** If any error occurs, `testcase_repr_cba_create` shall fail and return NULL. **]**

### testcase_repr_cba_create_with_move_buffers

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_with_move_buffers, CONSTBUFFER_HANDLE*, buffers, uint32_t, buffer_count);
```

`testcase_repr_cba_create_with_move_buffers` creates a new const buffer array made of the const buffers in `buffers` with move memory semantics for `buffers`.

Note: `testcase_repr_cba_create_with_move_buffers` does not increment the reference count of the buffer handles in `buffers`.

**SRS_TESTCASE_REPR_CBA_01_028: [** If `buffers` is `NULL` and `buffer_count` is not 0, `testcase_repr_cba_create_with_move_buffers` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_01_029: [** Otherwise, `testcase_repr_cba_create_with_move_buffers` shall allocate memory for a new `testcase_repr_cba_HANDLE` that holds the const buffers in `buffers`. **]**

**SRS_TESTCASE_REPR_CBA_01_031: [** On success `testcase_repr_cba_create_with_move_buffers` shall return a non-`NULL` handle. **]**

**SRS_TESTCASE_REPR_CBA_01_030: [** If any error occurs, `testcase_repr_cba_create_with_move_buffers` shall fail and return `NULL`. **]**

### testcase_repr_cba_create_from_buffer_index_and_count

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_buffer_index_and_count, testcase_repr_cba_HANDLE, original, uint32_t, start_buffer_index, uint32_t, buffer_count);
```

`testcase_repr_cba_create_from_buffer_index_and_count` creates a new const buffer array which is a subset of the existing array in `original`.

Note: `testcase_repr_cba_create_from_buffer_index_and_count` does not increment the reference count of the buffer handles in `original`, it just increments the reference count on `original`.

**SRS_TESTCASE_REPR_CBA_42_010: [** If `original` is `NULL` then `testcase_repr_cba_create_from_buffer_index_and_count` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_42_011: [** If `start_buffer_index` is greater than the number of buffers in `original` then `testcase_repr_cba_create_from_buffer_index_and_count` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_42_012: [** If `start_buffer_index + buffer_count` is greater than the number of buffers in `original` then `testcase_repr_cba_create_from_buffer_index_and_count` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_42_013: [** `testcase_repr_cba_create_from_buffer_index_and_count` shall allocate memory for a new `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_42_014: [** `testcase_repr_cba_create_from_buffer_index_and_count` shall increment the reference count on `original`. **]**

**SRS_TESTCASE_REPR_CBA_42_015: [** `testcase_repr_cba_create_from_buffer_index_and_count` shall return a non-`NULL` handle. **]**

**SRS_TESTCASE_REPR_CBA_42_016: [** If any error occurs then `testcase_repr_cba_create_from_buffer_index_and_count` shall fail and return `NULL`. **]**

### testcase_repr_cba_create_from_buffer_offset_and_count

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_buffer_offset_and_count, testcase_repr_cba_HANDLE, original, uint32_t, start_buffer_index, uint32_t, buffer_count, uint32_t, start_buffer_offset, uint32_t, end_buffer_size)
```

`testcase_repr_cba_create_from_buffer_offset_and_count` creates a new const buffer array which is a subset of the existing array in `original`.

**SRS_TESTCASE_REPR_CBA_07_001: [** If `original` is `NULL` then `testcase_repr_cba_create_from_buffer_offset_and_count` shall fail and return `NULL`.  **]**

**SRS_TESTCASE_REPR_CBA_07_002: [** If `start_buffer_index` is greater than the number of buffers in `original` then `testcase_repr_cba_create_from_buffer_offset_and_count` shall fail and return `NULL`.  **]**

**SRS_TESTCASE_REPR_CBA_07_003: [** If `start_buffer_index + buffer_count` is greater than the number of buffers in `original` then `testcase_repr_cba_create_from_buffer_offset_and_count` shall fail and return `NULL`.  **]**

**SRS_TESTCASE_REPR_CBA_07_015: [** If `buffer_count` is equal to original buffer count, start buffer offset is `0` and end buffer offset is equal to the size of the last buffer in `original`, then `testcase_repr_cba_create_from_buffer_offset_and_count` shall increment the reference count of `original` and return `original`.  **]**

**SRS_TESTCASE_REPR_CBA_07_013: [** If `buffer_count` is 1, `testcase_repr_cba_create_from_buffer_offset_and_count` shall get the only buffer by calling `CONSTBUFFER_CreateFromOffsetAndSize` with paramter `start_buffer_offset` and `end_buffer_size`. **]**

**SRS_TESTCASE_REPR_CBA_07_011: [** `testcase_repr_cba_create_from_buffer_offset_and_count` shall compute the start buffer size.  **]**

**SRS_TESTCASE_REPR_CBA_07_005: [** `testcase_repr_cba_create_from_buffer_offset_and_count` shall get the start buffer by calling `CONSTBUFFER_CreateFromOffsetAndSize`. **]**

**SRS_TESTCASE_REPR_CBA_07_012: [** `testcase_repr_cba_create_from_buffer_offset_and_count` shall get the end buffer by calling `CONSTBUFFER_CreateFromOffsetAndSize`. **]**

**SRS_TESTCASE_REPR_CBA_07_007: [**  `testcase_repr_cba_create_from_buffer_offset_and_count` shall allocate memory for a new `testcase_repr_cba_HANDLE`.  **]**

**SRS_TESTCASE_REPR_CBA_07_008: [** `testcase_repr_cba_create_from_buffer_offset_and_count` shall copy all of the CONSTBUFFER_HANDLES except first and last buffer from each const buffer array in buffer_arrays to the newly constructed array by calling CONSTBUFFER_IncRef. **]**

**SRS_TESTCASE_REPR_CBA_07_009: [** `testcase_repr_cba_create_from_buffer_offset_and_count` shall return a non-`NULL` handle.  **]**

**SRS_TESTCASE_REPR_CBA_07_014: [** If any error occurs then `testcase_repr_cba_create_from_buffer_offset_and_count` shall fail and return `NULL`. **]**

### testcase_repr_cba_create_empty

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_empty);
```

`testcase_repr_cba_create_empty` creates a new, empty testcase_repr_cba_HANDLE.

**SRS_TESTCASE_REPR_CBA_02_004: [** `testcase_repr_cba_create_empty` shall allocate memory for a new `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_02_041: [** `testcase_repr_cba_create_empty` shall succeed and return a non-`NULL` value. **]**

**SRS_TESTCASE_REPR_CBA_02_001: [** If are any failure is encountered, `testcase_repr_cba_create_empty` shall fail and return `NULL`. **]**

### testcase_repr_cba_create_from_array_array

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_create_from_array_array, const testcase_repr_cba_HANDLE*, buffer_arrays, uint32_t, buffer_array_count);
```

`testcase_repr_cba_create_from_array_array` creates a new const buffer array made of all the const buffers in `buffer_arrays`.

**SRS_TESTCASE_REPR_CBA_42_009: [** If `buffer_arrays` is `NULL` and `buffer_array_count` is not 0 then `testcase_repr_cba_create_from_array_array` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_42_001: [** If `buffer_arrays` is `NULL` or `buffer_array_count` is 0 then `testcase_repr_cba_create_from_array_array` shall create a new, empty `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_42_002: [** If any const buffer array in `buffer_arrays` is `NULL` then `testcase_repr_cba_create_from_array_array` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_42_003: [** `testcase_repr_cba_create_from_array_array` shall allocate memory to hold all of the `CONSTBUFFER_HANDLES` from `buffer_arrays`. **]**

**SRS_TESTCASE_REPR_CBA_42_004: [** `testcase_repr_cba_create_from_array_array` shall copy all of the `CONSTBUFFER_HANDLES` from each const buffer array in `buffer_arrays` to the newly constructed array by calling `CONSTBUFFER_IncRef`. **]**

**SRS_TESTCASE_REPR_CBA_42_007: [** `testcase_repr_cba_create_from_array_array` shall succeed and return a non-`NULL` value. **]**

**SRS_TESTCASE_REPR_CBA_42_008: [** If there are any failures then `testcase_repr_cba_create_from_array_array` shall fail and return `NULL`. **]**

### testcase_repr_cba_remove_empty_buffers

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_remove_empty_buffers, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);
```

`testcase_repr_cba_remove_empty_buffers` creates a new const buffer array with all zero-sized buffers removed from the original array.

**SRS_TESTCASE_REPR_CBA_88_001: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_remove_empty_buffers` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_88_002: [** `testcase_repr_cba_remove_empty_buffers` shall get the buffer count from `testcase_repr_cba_handle`. **]**

**SRS_TESTCASE_REPR_CBA_88_003: [** `testcase_repr_cba_remove_empty_buffers` shall examine each buffer in `testcase_repr_cba_handle` to determine if it is empty (size equals 0). **]**

**SRS_TESTCASE_REPR_CBA_88_004: [** If no buffers in `testcase_repr_cba_handle` are empty, `testcase_repr_cba_remove_empty_buffers` shall increment the reference count of `testcase_repr_cba_handle` and return `testcase_repr_cba_handle`. **]**

**SRS_TESTCASE_REPR_CBA_88_005: [** If all buffers in `testcase_repr_cba_handle` are empty, `testcase_repr_cba_remove_empty_buffers` shall create and return a new empty `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_88_006: [** `testcase_repr_cba_remove_empty_buffers` shall allocate memory for a new `testcase_repr_cba_HANDLE` that can hold only the non-empty buffers. **]**

**SRS_TESTCASE_REPR_CBA_88_007: [** `testcase_repr_cba_remove_empty_buffers` shall copy all non-empty buffers from `testcase_repr_cba_handle` to the new const buffer array. **]**

**SRS_TESTCASE_REPR_CBA_88_008: [** `testcase_repr_cba_remove_empty_buffers` shall increment the reference count of all copied buffers. **]**

**SRS_TESTCASE_REPR_CBA_88_009: [** On success `testcase_repr_cba_remove_empty_buffers` shall return a non-`NULL` handle. **]**

**SRS_TESTCASE_REPR_CBA_88_010: [** If any error occurs, `testcase_repr_cba_remove_empty_buffers` shall fail and return `NULL`. **]**

### testcase_repr_cba_inc_ref

```c
MOCKABLE_FUNCTION(, void, testcase_repr_cba_inc_ref, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);
```

`testcase_repr_cba_inc_ref` increments the reference count for `testcase_repr_cba_handle`.

**SRS_TESTCASE_REPR_CBA_01_017: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_inc_ref` shall return. **]**

**SRS_TESTCASE_REPR_CBA_01_018: [** Otherwise `testcase_repr_cba_inc_ref` shall increment the reference count for `testcase_repr_cba_handle`. **]**

### testcase_repr_cba_dec_ref

```c
MOCKABLE_FUNCTION(, void, testcase_repr_cba_dec_ref, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);
```

`testcase_repr_cba_dec_ref` decrements the reference count and frees all used resources if needed.

**SRS_TESTCASE_REPR_CBA_02_039: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_dec_ref` shall return. **]**

**SRS_TESTCASE_REPR_CBA_01_016: [** Otherwise `testcase_repr_cba_dec_ref` shall decrement the reference count for `testcase_repr_cba_handle`. **]**

**SRS_TESTCASE_REPR_CBA_02_038: [** If the reference count reaches 0, `testcase_repr_cba_dec_ref` shall free all used resources. **]**

### testcase_repr_cba_add_front

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_add_front, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE, constbuffer_handle);
```

`testcase_repr_cba_add_front` adds a new `CONSTBUFFER_HANDLE` at the front of the already stored `CONSTBUFFER_HANDLE`s.

**SRS_TESTCASE_REPR_CBA_02_006: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_add_front` shall fail and return `NULL` **]**

**SRS_TESTCASE_REPR_CBA_02_007: [** If `constbuffer_handle` is `NULL` then `testcase_repr_cba_add_front` shall fail and return `NULL` **]**

**SRS_TESTCASE_REPR_CBA_02_042: [** `testcase_repr_cba_add_front` shall allocate enough memory to hold all of `testcase_repr_cba_handle` existing `CONSTBUFFER_HANDLE` and `constbuffer_handle`. **]**

**SRS_TESTCASE_REPR_CBA_02_043: [** `testcase_repr_cba_add_front` shall copy `constbuffer_handle` and all of `testcase_repr_cba_handle` existing `CONSTBUFFER_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_02_044: [** `testcase_repr_cba_add_front` shall inc_ref all the `CONSTBUFFER_HANDLE` it had copied. **]**

**SRS_TESTCASE_REPR_CBA_02_010: [** `testcase_repr_cba_add_front` shall succeed and return a non-`NULL` value. **]**

**SRS_TESTCASE_REPR_CBA_02_011: [** If there any failures `testcase_repr_cba_add_front` shall fail and return `NULL`. **]**

### testcase_repr_cba_remove_front

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_remove_front, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE* const_buffer_handle);
```

`testcase_repr_cba_remove_front` removes the front `CONSTBUFFER_HANDLE` and hands it over to the caller.

**SRS_TESTCASE_REPR_CBA_02_012: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_remove_front` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_02_045: [** If `constbuffer_handle` is `NULL` then `testcase_repr_cba_remove_front` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_02_013: [** If there is no front `CONSTBUFFER_HANDLE` then `testcase_repr_cba_remove_front` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_02_002: [** `testcase_repr_cba_remove_front` shall fail when called on an empty `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_02_046: [** `testcase_repr_cba_remove_front` shall allocate memory to hold all of `testcase_repr_cba_handle` `CONSTBUFFER_HANDLE`s except the front one. **]**

**SRS_TESTCASE_REPR_CBA_02_047: [** `testcase_repr_cba_remove_front` shall copy all of `testcase_repr_cba_handle` `CONSTBUFFER_HANDLE`s except the front one. **]**

**SRS_TESTCASE_REPR_CBA_02_048: [** `testcase_repr_cba_remove_front` shall inc_ref all the copied `CONSTBUFFER_HANDLE`s. **]**

**SRS_TESTCASE_REPR_CBA_01_001: [** `testcase_repr_cba_remove_front` shall inc_ref the removed buffer. **]**

**SRS_TESTCASE_REPR_CBA_02_049: [** `testcase_repr_cba_remove_front` shall succeed and return a non-`NULL` value. **]**

**SRS_TESTCASE_REPR_CBA_02_036: [** If there are any failures then `testcase_repr_cba_remove_front` shall fail and return `NULL`. **]**

### testcase_repr_cba_add_back

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_add_back, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE, constbuffer_handle);
```

`testcase_repr_cba_add_back` adds a new `CONSTBUFFER_HANDLE` at the back of the already stored `CONSTBUFFER_HANDLE`s.

**SRS_TESTCASE_REPR_CBA_05_001: [** If `testcase_repr_cba_handle` is `NULL` then `testcase_repr_cba_add_back` shall fail and return `NULL`.**]**

**SRS_TESTCASE_REPR_CBA_05_002: [** If `constbuffer_handle` is `NULL` then `testcase_repr_cba_add_back` shall fail and return `NULL`.**]**

**SRS_TESTCASE_REPR_CBA_05_003: [** `testcase_repr_cba_add_back` shall allocate enough memory to hold all of `testcase_repr_cba_handle` existing `CONSTBUFFER_HANDLE` and `constbuffer_handle`. **]**

**SRS_TESTCASE_REPR_CBA_05_004: [** `testcase_repr_cba_add_back` shall copy `constbuffer_handle` and all of `testcase_repr_cba_handle` existing `CONSTBUFFER_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_05_005: [** `testcase_repr_cba_add_back` shall inc_ref all the `CONSTBUFFER_HANDLE` it had copied. **]**

**SRS_TESTCASE_REPR_CBA_05_006: [** `testcase_repr_cba_add_back` shall succeed and return a non-`NULL` value. ]**

**SRS_TESTCASE_REPR_CBA_05_007: [** If there any failures `testcase_repr_cba_add_back` shall fail and return `NULL`. **]**

### testcase_repr_cba_remove_back

```c
MOCKABLE_FUNCTION(, testcase_repr_cba_HANDLE, testcase_repr_cba_remove_back, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, CONSTBUFFER_HANDLE* const_buffer_handle);
```

`testcase_repr_cba_remove_back` removes the back `CONSTBUFFER_HANDLE` and hands it over to the caller.

**SRS_TESTCASE_REPR_CBA_05_008: [** If `testcase_repr_cba_handle` is NULL then `testcase_repr_cba_remove_back` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_05_009: [** If `constbuffer_handle` is NULL then `testcase_repr_cba_remove_back` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_05_010: [** `testcase_repr_cba_remove_back` shall fail when called on an empty `testcase_repr_cba_HANDLE`. **]**

**SRS_TESTCASE_REPR_CBA_05_011: [** If there is no back `CONSTBUFFER_HANDLE` then `testcase_repr_cba_remove_back` shall fail and return `NULL`. **]**

**SRS_TESTCASE_REPR_CBA_05_012: [** `testcase_repr_cba_remove_back` shall allocate memory to hold all of `testcase_repr_cba_handle` `CONSTBUFFER_HANDLE`s except the back one. **]**

**SRS_TESTCASE_REPR_CBA_05_013: [** `testcase_repr_cba_remove_back` shall inc_ref the removed buffer. **]**

**SRS_TESTCASE_REPR_CBA_05_014: [** `testcase_repr_cba_remove_back` shall write in `constbuffer_handle` the back handle. **]**

**SRS_TESTCASE_REPR_CBA_05_015: [** `testcase_repr_cba_remove_back` shall copy all of `testcase_repr_cba_handle` `CONSTBUFFER_HANDLE`s except the back one. **]**

**SRS_TESTCASE_REPR_CBA_05_016: [** `testcase_repr_cba_remove_back` shall inc_ref all the copied `CONSTBUFFER_HANDLE`s. **]**

**SRS_TESTCASE_REPR_CBA_05_017: [** `testcase_repr_cba_remove_back` shall succeed and return a non-`NULL` value. **]**

**SRS_TESTCASE_REPR_CBA_05_018: [** If there are any failures then `testcase_repr_cba_remove_back` shall fail and return `NULL`. **]**

### testcase_repr_cba_get_buffer_count

```c
MOCKABLE_FUNCTION(, int, testcase_repr_cba_get_buffer_count, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t*, buffer_count);
```

`testcase_repr_cba_get_buffer_count` gets the count of const buffers held by the const buffer array.

**SRS_TESTCASE_REPR_CBA_01_002: [** On success, `testcase_repr_cba_get_buffer_count` shall return 0 and write the buffer count in `buffer_count`. **]**

**SRS_TESTCASE_REPR_CBA_01_003: [** If `testcase_repr_cba_handle` is NULL, `testcase_repr_cba_get_buffer_count` shall fail and return a non-zero value. **]**

**SRS_TESTCASE_REPR_CBA_01_004: [** If `buffer_count` is NULL, `testcase_repr_cba_get_buffer_count` shall fail and return a non-zero value. **]**

### testcase_repr_cba_get_buffer

```c
MOCKABLE_FUNCTION(, CONSTBUFFER_HANDLE, testcase_repr_cba_get_buffer, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t, buffer_index);
```

`testcase_repr_cba_get_buffer` returns the buffer at the `buffer_index`-th given index in the array.

**SRS_TESTCASE_REPR_CBA_01_005: [** On success, `testcase_repr_cba_get_buffer` shall return a non-NULL handle to the `buffer_index`-th const buffer in the array. **]**

**SRS_TESTCASE_REPR_CBA_01_006: [** The returned handle shall have its reference count incremented. **]**

**SRS_TESTCASE_REPR_CBA_01_007: [** If `testcase_repr_cba_handle` is NULL, `testcase_repr_cba_get_buffer` shall fail and return NULL. **]**

**SRS_TESTCASE_REPR_CBA_01_008: [** If `buffer_index` is greater or equal to the number of buffers in the array, `testcase_repr_cba_get_buffer` shall fail and return NULL. **]**

### testcase_repr_cba_get_buffer_content

```c
MOCKABLE_FUNCTION(, const CONSTBUFFER*, testcase_repr_cba_get_buffer_content, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t, buffer_index);
```

`testcase_repr_cba_get_buffer_content` gets the buffer content for the buffer at the `buffer_index`-th given index in the array.

**SRS_TESTCASE_REPR_CBA_01_023: [** If `testcase_repr_cba_handle` is NULL, `testcase_repr_cba_get_buffer_content` shall fail and return NULL. **]**

**SRS_TESTCASE_REPR_CBA_01_024: [** If `buffer_index` is greater or equal to the number of buffers in the array, `testcase_repr_cba_get_buffer_content` shall fail and return NULL. **]**

**SRS_TESTCASE_REPR_CBA_01_025: [** Otherwise `testcase_repr_cba_get_buffer_content` shall call `CONSTBUFFER_GetContent` for the `buffer_index`-th buffer and return its result. **]**

### testcase_repr_cba_get_all_buffers_size

```c
MOCKABLE_FUNCTION(, int, testcase_repr_cba_get_all_buffers_size, testcase_repr_cba_HANDLE, testcase_repr_cba_handle, uint32_t*, all_buffers_size);
```

`testcase_repr_cba_get_all_buffers_size` gets the size for all buffers (how much memory is held by all buffers in the array).

**SRS_TESTCASE_REPR_CBA_01_019: [** If `testcase_repr_cba_handle` is NULL, `testcase_repr_cba_get_all_buffers_size` shall fail and return a non-zero value. **]**

**SRS_TESTCASE_REPR_CBA_01_020: [** If `all_buffers_size` is NULL, `testcase_repr_cba_get_all_buffers_size` shall fail and return a non-zero value. **]**

**SRS_TESTCASE_REPR_CBA_01_021: [** If summing up the sizes results in an `uint32_t` overflow, shall fail and return a non-zero value. **]**

**SRS_TESTCASE_REPR_CBA_01_022: [** Otherwise `testcase_repr_cba_get_all_buffers_size` shall write in `all_buffers_size` the total size of all buffers in the array and return 0. **]**

### testcase_repr_cba_get_const_buffer_handle_array

```c
MOCKABLE_FUNCTION(, const CONSTBUFFER_HANDLE*, testcase_repr_cba_get_const_buffer_handle_array, testcase_repr_cba_HANDLE, testcase_repr_cba_handle);
```

`testcase_repr_cba_get_const_buffer_handle_array` gets a const array with the handles for all the const buffers in the array.

**SRS_TESTCASE_REPR_CBA_01_026: [** If `testcase_repr_cba_handle` is NULL, `testcase_repr_cba_get_const_buffer_handle_array` shall fail and return NULL. **]**

**SRS_TESTCASE_REPR_CBA_01_027: [** Otherwise `testcase_repr_cba_get_const_buffer_handle_array` shall return the array of const buffer handles backing the const buffer array. **]**

### testcase_repr_cba_HANDLE_contain_same
```c
MOCKABLE_FUNCTION(, bool, testcase_repr_cba_HANDLE_contain_same, testcase_repr_cba_HANDLE, left, testcase_repr_cba_HANDLE, right);
```

`testcase_repr_cba_HANDLE_contain_same` returns `true` if `left` and `right` have the some content.

**SRS_TESTCASE_REPR_CBA_02_050: [** If `left` is `NULL` and `right` is `NULL` then `testcase_repr_cba_HANDLE_contain_same` shall return `true`. **]**

**SRS_TESTCASE_REPR_CBA_02_051: [** If `left` is `NULL` and `right` is not `NULL` then `testcase_repr_cba_HANDLE_contain_same` shall return `false`. **]**

**SRS_TESTCASE_REPR_CBA_02_052: [** If `left` is not `NULL` and `right` is `NULL` then `testcase_repr_cba_HANDLE_contain_same` shall return `false`. **]**

**SRS_TESTCASE_REPR_CBA_02_053: [** If the number of `CONSTBUFFER_HANDLE`s in `left` is different then the number of `CONSTBUFFER_HANDLE`s in `right` then  `testcase_repr_cba_HANDLE_contain_same` shall return `false`. **]**

**SRS_TESTCASE_REPR_CBA_02_054: [** If `left` and `right` `CONSTBUFFER_HANDLE`s at same index are different (as indicated by `CONSTBUFFER_HANDLE_contain_same` call) then `testcase_repr_cba_HANDLE_contain_same` shall return `false`. **]**

**SRS_TESTCASE_REPR_CBA_02_055: [** `testcase_repr_cba_HANDLE_contain_same` shall return `true`. **]**

