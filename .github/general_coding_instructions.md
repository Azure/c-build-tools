# Azure Messaging Block Storage - General Coding Guidelines

## Overview {#overview}
This document establishes coding standards and conventions for the Azure Messaging Block Storage (EBS) project. These guidelines ensure consistency, maintainability, and alignment with Azure C library patterns used throughout the codebase.

## Function Naming Conventions {#function-naming}

### API Function Naming
- Use **lowercase with underscores** (snake_case) for all function names
- **NEVER use camelCase, PascalCase, or any mixed-case naming**
- Follow the pattern: `<module_prefix>_<action>[_<qualifier>]`
- Examples:
  - `bsdl_address_list_create()`
  - `block_storage_append_async()`
  - `msi_token_cache_get_token()`
  - `operation_limiter_acquire()`

### Internal Function Naming
- **Internal functions must be declared `static`** and not exposed through public headers
- **Prefix internal functions with `internal_` followed by the module name**:
  - Pattern: `internal_<module_prefix>_<action>[_<qualifier>]`
  - Examples:
    - `static int internal_bsdl_validate_parameters(...)`
    - `static void internal_bs_cleanup_resources(...)`
    - `static void internal_bsdl_ordered_writer_close(...)`
    - `static RESULT_TYPE internal_sf_process_callback(...)`
- This clearly distinguishes internal implementation details from public API

### Module Prefixes
- Use consistent module prefixes that identify the component:
  - `bsdl_*` - Block Storage Data Layer functions
  - `bs_*` - Block Storage functions
  - `sf_*` - Service Fabric related functions
  - `zrpc_*` - ZRPC framework functions

### Function Categories
- **Creation/Destruction**: `*_create()`, `*_destroy()`, `*_cleanup()`
- **Lifecycle Management**: `*_open()`, `*_close()`, `*_init()`, `*_deinit()`
- **Reference Counting**: `*_inc_ref()`, `*_dec_ref()`
- **Async Operations**: `*_async()` suffix for asynchronous functions
- **Getters/Setters**: `*_get_*()`, `*_set_*()`
- **Internal Functions**: `internal_*_*()` prefix for static, non-public functions

### Function Visibility Rules
- **Public API functions**: Declared in header files, no `static` keyword, follow public naming conventions
- **Internal functions**: Must be `static`, prefixed with `internal_*_`, not declared in public headers
- **Helper functions**: Use appropriate internal naming if they're implementation details

## Function Structure Guidelines {#function-structure}

### Function Organization
- **Parameter validation first**: Always validate parameters at the beginning of the function
- **Variable declarations**: Declare variables when first needed (C99+ style) to improve readability and reduce scope
- **Single exit point**: Always use goto for cleanup and maintain exactly one return statement per function
- **Error handling**: Use consistent result variable patterns for error propagation

### Function Length and Complexity
- **Keep functions focused**: Each function should have a single, well-defined responsibility
- **Limit function length**: Prefer functions under 100 lines; split complex functions into helpers
- **Minimize nesting**: Use goto patterns to reduce nesting levels and maintain single exit point
- **Use helper functions**: Extract common logic into appropriately named internal helper functions

### Documentation and Comments
- **Function purpose**: Document what the function does, not how it does it
- **Complex logic**: Add inline comments for non-obvious algorithms or business logic

### Async Function Callback Patterns {#async-callbacks}
Asynchronous operations must follow consistent callback patterns for error handling and result delivery:

```c
// Standard async callback signature
typedef void(*MY_ASYNC_CALLBACK)(
    void* context,                    // User-provided context
    MY_RESULT result,                 // Operation result (success/failure)
    /* ... additional result data ... */
);

// Async function signature pattern
int my_operation_async(
    MY_HANDLE handle,
    const char* param,
    MY_ASYNC_CALLBACK callback,       // Callback function
    void* callback_context            // User context passed to callback
);
```

**Async Callback Rules:**
- **Error vs Success behavior**: If async function returns error, callback is NEVER called. If async function returns success, callback is called exactly ONCE
- **Single callback invocation**: Each successfully started async operation calls the callback exactly once
- **Context preservation**: Pass user context through unchanged to callback
- **Error reporting**: Use result parameter to indicate success/failure
- **Thread safety**: Callbacks may be invoked from any thread

**Async Implementation Pattern:**
```c
int my_operation_async(MY_HANDLE handle, const char* param, MY_ASYNC_CALLBACK callback, void* context)
{
    int result;

    // Parameter validation
    if (
        (handle == NULL) ||
        (callback == NULL)
        )
    {
        LogError("Invalid arguments MY_HANDLE handle=%p, MY_ASYNC_CALLBACK callback=%p, void* context=%p", handle, callback, context);
        result = MU_FAILURE;
    }
    else
    {
        // Start async work
        if (start_async_work(handle, param, callback, context) == 0)
        {
            result = 0;  // Async operation started successfully
            goto callback_will_come;
        }
        else
        {
            result = MU_FAILURE;  // Failed to start async operation
        }
    }

callback_will_come:
    return result;
}
```

## Variable Naming Conventions {#variable-naming}

### General Rules
- Use **lowercase with underscores** (snake_case) for all variable names
- **NEVER use camelCase, PascalCase, or any mixed-case naming**
- Use descriptive names that clearly indicate purpose
- Avoid single-letter variables except for loop counters (`i`, `j`, `k`)

### Specific Patterns
```c
// Local variables
int result = 0;
THANDLE(BSDL_ADDRESS_LIST) temp = NULL;
uint32_t record_count = 0;
bool is_success = false;

// Function parameters
BSDL_FILE_HL_HANDLE bsdl_file_hl_handle
const char* full_file_name
CONSTBUFFER_HANDLE user_metadata
void* user_context

// Structure members
typedef struct EXAMPLE_TAG
{
    uint32_t item_count;
    BSDL_ADDRESS_HANDLE* address_list;
    volatile_atomic int32_t ref_count;
} EXAMPLE;
```

### Special Variable Types
- **Handles**: Use `*_handle` suffix for handle variables
- **Callbacks**: Use `*_callback` suffix for callback function pointers
- **Contexts**: Use `*_context` suffix for context parameters
- **Results**: Always use `result` for function return values
- **Temporaries**: Use `temp` or `tmp_*` prefix for temporary variables

## Result Variable Conventions {#result-variables}

### Initialization
- **Avoid initializing result variables when possible** to ensure all code paths explicitly set a value:
```c
// Preferred - uninitialized to catch missing assignments
int result;
TYPE_HANDLE result;
TYPE_RESULT result;

// EXCEPTION: THANDLE types must always be initialized to NULL
THANDLE(TYPE) result = NULL;  // Required for reference-counted types

// Only initialize others when necessary (e.g., when goto jumps over assignments)
int result = MU_FAILURE;  // when using goto that skips the main logic
```

### Ensuring All Paths Set Results
- **Every code path must explicitly set the result variable**
- **THANDLE types are an exception** - they must be initialized to NULL for proper reference counting
- Use compiler warnings (`-Wuninitialized`) to catch missing assignments for non-THANDLE types
- This pattern helps identify bugs where error paths don't set return values

### Return Patterns
- Use consistent return value patterns:
  - `0` for success, non-zero for failure (integer functions)
  - `NULL` for failure (pointer/handle functions)
  - Specific enum values for typed results
- **Every code path must explicitly assign the result variable**
- **THANDLE types must be initialized to NULL** due to reference counting requirements
- Use uninitialized variables and compiler warnings to catch missing assignments for non-THANDLE types

### Return Value Handling
- **All function return values must be checked or explicitly ignored**
- Use `(void)` cast to explicitly indicate intentional ignoring of return values:

```c
// Correct - checking return value
int result = some_function();
if (result != 0)
{
    LogError("some_function failed with result %d", result);
    // handle error
}

// Correct - explicitly ignoring return value when appropriate
(void)interlocked_exchange(&state, NEW_STATE);  // State change, return value not needed
(void)printf("Debug message\n");               // Printf return value rarely needed

// Incorrect - ignoring return value without explicit cast
some_function();  // Compiler should warn about unused return value
```

- This rule applies to all functions that return values, including:
  - Error codes (`int`, custom result enums)
  - Pointers and handles
  - Boolean values
  - Any other return types

## Parameter Validation Rules {#parameter-validation}

### Validation Order
**Parameter validation must be performed FIRST** in every function, before any other operations:

```c
THANDLE(TYPE) my_function_create(uint32_t count, TYPE_HANDLE* items)
{
    THANDLE(TYPE) result = NULL;  // THANDLE must be initialized to NULL

    // Parameter validation comes FIRST - before any allocations or operations
    if (
        /*Codes_SRS_MODULE_42_001: [ If count is zero then my_function_create shall fail and return NULL. ]*/
        (count == 0) ||
        /*Codes_SRS_MODULE_42_002: [ If items is NULL then my_function_create shall fail and return NULL. ]*/
        (items == NULL)
        )
    {
        LogError("invalid arguments uint32_t count=%" PRIu32 ", TYPE_HANDLE* items=%p", count, items);
        result = NULL;  // Explicit assignment in error path (though already NULL)
    }
    else
    {
        // Actual function implementation follows validation
        result = create_actual_object(count, items);  // Must set result in success path
    }

    return result;
}
```

### Validation Patterns
- Check for `NULL` pointers first
- Validate value ranges and constraints
- **Combine all validations in a single `if` statement** with `||` operator whenever possible (avoid multiple separate `if` statements for parameter checks)
- **Log ALL function arguments when validation fails** - include every parameter with its type and value in the `LogError()` call, not just the invalid ones
- Use `LogError()` to log validation failures with parameter values
- Include SRS requirement comments for each validation

## Goto Usage Rules {#goto-usage}

### Permitted Uses
Goto is **permitted and encouraged** for the following patterns:

#### 1. Success Path (Most Common)
```c
int my_function(void)
{
    int result;  // Uninitialized - all paths must set it

    if (condition1_failed)
    {
        LogError("condition1 failed");
        result = MU_FAILURE;  // Error path sets result
    }
    else if (condition2_failed)
    {
        LogError("condition2 failed");
        result = MU_FAILURE;  // Error path sets result
    }
    else
    {
        // Success path - check return values
        if (perform_operation() != 0)
        {
            LogError("perform_operation failed");
            result = MU_FAILURE;
        }
        else
        {
            result = 0;  // Success path sets result
            goto all_ok;
        }
    }

    // Cleanup code here
    cleanup_resources();

all_ok:
    return result;
}
```

#### 2. Async Callback Continuation
```c
int my_async_function(HANDLE handle, CALLBACK callback, void* context)
{
    int result;  // Uninitialized - all paths must set it

    if (validation_failed)
    {
        LogError("validation failed");
        result = MU_FAILURE;  // Error path sets result
    }
    else
    {
        if (start_async_operation() != 0)
        {
            result = MU_FAILURE;  // Async start failure sets result
        }
        else
        {
            result = 0;  // Success path sets result
            goto all_ok;
        }
    }

    // Synchronous error path - call callback immediately
    callback(context, ERROR_RESULT);

all_ok:
    return result;
}
```

### Multi-Level Cleanup Placement
When multiple operations need cleanup, place each undo at the end of the corresponding `else` block. This ensures:
1. Cleanup is only executed on error paths
2. Cleanup code is not duplicated across error branches
3. Undos execute in reverse order (LIFO)

```c
int my_open_function(HANDLE handle)
{
    int result;

    if (sm_open_begin(handle->sm) != SM_EXEC_GRANTED)
    {
        LogError("sm_open_begin failed");
        result = MU_FAILURE;
    }
    else
    {
        if (resource_open(handle->resource) != 0)
        {
            LogError("resource_open failed");
            result = MU_FAILURE;
        }
        else
        {
            if (start_async_operation(handle) != 0)
            {
                LogError("start_async_operation failed");
                result = MU_FAILURE;
            }
            else
            {
                result = 0;
                goto all_ok;
            }
            // Undo resource_open - only reached if start_async_operation failed
            resource_close(handle->resource);
        }
        // Undo sm_open_begin - reached if resource_open or start_async_operation failed
        sm_open_end(handle->sm, false);
    }

all_ok:
    return result;
}
```

**Key principles:**
- Each undo goes at the end of the `else` block for the operation it undoes
- Undos are executed in reverse order of the operations (LIFO)
- `goto all_ok` skips ALL cleanup on success
- Never duplicate cleanup calls across error paths

### `all_ok` Label Placement
The `all_ok` label must go after the "undo".

```c
// Incorrect - code between label and return
all_ok:
    free(buffer);       // Don't put code here
    return result;

// Correct - label immediately before return
all_ok:
    return result;
```

If there are any "undo" operations that must be performed even in the success case, they can go after the all_ok label:

```c
srw_lock_acquire();
if (sm_exec_begin(handle->sm) != SM_EXEC_GRANTED)
{
    LogError("sm_exec_begin failed");
    result = MU_FAILURE;
}
else
{
    if (do_work(handle) != 0)
    {
        LogError("do_work failed");
        result = MU_FAILURE;
    }
    else
    {
        result = 0;
        goto all_ok;
    }
    // Cleanup at END of else block - only reached on error
    sm_exec_end(handle->sm);
}

all_ok:
srw_lock_release(); // lock must always be released
return result;
```

### Label Naming
- Use descriptive, lowercase labels with underscores: `all_ok`, `cleanup`, `callback_will_come`
- Prefer snake_case for consistency with function and variable naming
- Common patterns: `all_ok`, `cleanup`, `callback_will_come`, `no_cleanup`

### Prohibited Uses
- **Never use goto for loop control** (use proper loop constructs)
- **Never use goto to jump into nested scopes**

## Indentation and Formatting {#indentation-formatting}

### Indentation
- Use **4 spaces** for indentation (no tabs)
- Align continuation lines consistently
- Align multi-line parameter lists:

```c
int long_function_name(
    VERY_LONG_TYPE_NAME* first_parameter,
    ANOTHER_LONG_TYPE_NAME* second_parameter,
    uint32_t third_parameter,
    const char* fourth_parameter
    )
```

### Braces and Spacing
- **Use Allman brace style** - opening braces on new lines for all constructs:
```c
int my_function(void)
{
    if (condition)
    {
        // code
    }
    else
    {
        // code
    }

    while (condition)
    {
        // code
    }

    for (uint32_t i = 0; i < count; i++)
    {
        // code
    }
}
```

- **Space after keywords**: `if (`, `while (`, `for (`
- **No space for function calls**: `function(param)`

## If/Else Formatting Rules {#if-else-formatting}

### Every `if` Must Have an `else`
Every `if` statement must have an explicit `else` block. This ensures all code paths are intentionally handled and makes the logic clear to reviewers:

```c
// Incorrect - missing else
if (!error)
{
    result = 0;
}

// Correct - explicit else
if (error_condition)
{
    LogError("...");
    result = MU_FAILURE;
}
else
{
    // Success path
    result = 0;
}
```

### Empty Else Blocks with "Do Nothing" Comment
When an `if` statement handles a condition but the `else` case requires no action, add an explicit empty `else` block with a `/* do nothing */` comment:

```c
// Correct - explicit else with "do nothing" comment
if (item == NULL)
{
    /* do nothing */
}
else
{
    process_item(item);
}
```

### Error Path in `if`, Success Path in `else`
The **error/nothing-to-do** path always goes in the `if` block; the **success/main code** path goes in the `else` block:

```c
// Correct - error in if, success in else
if (handle == NULL)
{
    LogError("invalid argument");
    result = MU_FAILURE;
}
else
{
    // Main logic here
    result = perform_operation(handle);
}
```

### Multi-Condition Validation
```c
if (
    /*Codes_SRS_MODULE_42_001: [ If param1 is NULL then function shall fail. ]*/
    (param1 == NULL) ||
    /*Codes_SRS_MODULE_42_002: [ If param2 is zero then function shall fail. ]*/
    (param2 == 0) ||
    /*Codes_SRS_MODULE_42_003: [ If param3 is invalid then function shall fail. ]*/
    (param3 < MIN_VALUE)
    )
{
    LogError("invalid arguments...");
}
```

### Consistent Bracing
- **Always use braces** even for single statements
- **Use Allman style** - opening braces on new lines:
```c
// Correct
if (condition)
{
    do_something();
}

// Incorrect - missing braces
if (condition)
    do_something();

// Incorrect - brace on same line
if (condition) {
    do_something();
}
```

### Error Handling Chains
```c
int result;

if (first_operation() != 0)
{
    LogError("first operation failed");
    result = MU_FAILURE;
}
else
{
    if (second_operation() != 0)
    {
        LogError("second operation failed");
        result = MU_FAILURE;
    }
    else
    {
        // Success path - note the explicit return value checking
        result = 0;
    }
}

// Example of explicitly ignoring return values when appropriate
(void)interlocked_exchange(&cleanup_state, CLEANED_UP);
```

## Additional Conventions {#additional-conventions}

### Mockable Function Declarations {#mockable-functions}
For functions that need to be mocked in unit tests, use `MOCKABLE_FUNCTION` or `MOCKABLE_FUNCTION_WITH_RETURNS` in header files:

```c
// In header file (e.g., my_module.h)
#include "umock_c/umock_c_prod.h"

// Basic mockable function declaration
MOCKABLE_FUNCTION(, int, my_module_function, int, param1, const char*, param2);

// Preferred: MOCKABLE_FUNCTION_WITH_RETURNS when success/failure values are known
// Syntax: MOCKABLE_FUNCTION_WITH_RETURNS(, return_type, function_name, params...)(success_value, failure_value);
MOCKABLE_FUNCTION_WITH_RETURNS(, MY_RESULT, my_module_operation, int, param1, const char*, param2)(MY_RESULT_OK, MY_RESULT_ERROR);

// In implementation file (e.g., my_module.c)
int my_module_function(int param1, const char* param2)
{
    // Implementation
    return 0;
}
```

**MOCKABLE_FUNCTION Rules:**
- **Prefer `MOCKABLE_FUNCTION_WITH_RETURNS`**: When the function has known success and failure return values, use `MOCKABLE_FUNCTION_WITH_RETURNS` to enable automatic mock return value registration
- **Use for external dependencies**: Mock functions that your module calls from other modules
- **Use for testable isolation**: Mock functions to isolate the unit under test
- **Include umock_c header**: Always include `umock_c/umock_c_prod.h` when using MOCKABLE_FUNCTION
- **Don't mock internal functions**: Only mock functions that cross module boundaries
- **Maintain function signature**: The MOCKABLE_FUNCTION signature must exactly match the implementation

### Function Visibility and Encapsulation
```c
// Public API function - declared in header file
int bsdl_address_list_create(uint32_t count, BSDL_ADDRESS_HANDLE* addresses);

// Internal helper function - static, not in header
static int bsdl_internal_validate_address_array(uint32_t count, BSDL_ADDRESS_HANDLE* addresses)
{
    int result;
    uint32_t i;

    // Implementation details not exposed to callers
    for (i = 0; i < count; i++)
    {
        if (addresses[i] == NULL)
        {
            break;  // Break on error
        }
    }

    // Check if loop completed successfully
    if (i < count)
    {
        result = MU_FAILURE;  // Loop broke due to error
    }
    else
    {
        result = 0;  // Loop completed successfully
    }

    return result;
}

// Usage in public function
int bsdl_address_list_create(uint32_t count, BSDL_ADDRESS_HANDLE* addresses)
{
    int result;

    if (bsdl_internal_validate_address_array(count, addresses) != 0)
    {
        LogError("Address validation failed");
        result = MU_FAILURE;
    }
    else
    {
        // Create the address list
        result = 0;
    }

    return result;
}
```

### Header Inclusion Order

Headers must be included in a specific order to ensure proper compilation and avoid conflicts:

1. **Standard C Library Headers** (first)
2. **System/Platform Headers**
3. **Test Framework Headers** (for test files only)
4. **Memory Management Headers** (gballoc_hl_redirect.h - MANDATORY)
5. **Core Infrastructure Headers** (macro_utils, c_logging)
6. **Submodule Headers** (dependency order - highest depth first)
7. **Project-Specific Headers** (last)

#### Memory Management Requirement
**MANDATORY**: All source files (.c/.cpp) that perform dynamic memory allocation must include:
```c
#include "c_pal/gballoc_hl_redirect.h"
```

**Rules:**
- **Include early**: Place after system headers but before other project headers
- **Never skip**: Required even if the file doesn't directly call malloc/free
- **Single inclusion**: Include only once per compilation unit
- **Macro redirection**: This header redirects malloc/free calls to the configured allocator (jemalloc, mimalloc, or system)

#### Detailed Header Inclusion Order with Examples

**1. Standard C Library Headers (first):**
```c
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <math.h>
```

**2. System/Platform Headers (after standard C):**
```c
#include "windows.h"        // Windows-specific headers
#include "winsock2.h"       // Network headers when needed
#include "fabrictypes.h"    // Service Fabric headers
```

**3. Test Framework Headers (for test files only):**
```c
#include "testrunnerswitcher.h"
#include "umock_c/umock_c.h"
#include "umock_c/umocktypes_*.h"
```

**4. Memory Management Headers (MANDATORY):**
```c
#include "c_pal/gballoc_hl_redirect.h"  // REQUIRED for all .c/.cpp files
```

**5. Core Infrastructure Headers (required order):**
```c
#include "macro_utils/macro_utils.h"  // ALWAYS first infrastructure header
#include "c_logging/logger.h"         // ALWAYS second
```

**6. Submodule Headers (dependency order - highest depth first):**

The order of headers from various submodules follows the dependency chain, with headers from submodules with the highest depth (fewest dependencies) first, then decreasing depth order:

```c
// c_pal layer (highest depth - platform abstraction, no dependencies on other submodules)
#include "c_pal/gballoc_hl.h"
#include "c_pal/gballoc_hl_redirect.h"
#include "c_pal/interlocked.h"
#include "c_pal/string_utils.h"
#include "c_pal/sync.h"
#include "c_pal/thandle.h"
// ... other c_pal headers

// c_util layer (depends on c_pal)
#include "c_util/constbuffer.h"
#include "c_util/constbuffer_array.h"
#include "c_util/rc_string.h"
// ... other c_util headers

// clds (depends on c_pal, c_util, etc.)
#include "clds/clds_hash_table.h"          // depends on c_pal, c_util

// zrpc (depends on c_pal, c_util, etc.)
#include "zrpc/zrpc_client.h"              // depends on c_pal, c_util

// etc.
```

**Dependency Chain Example:** zrpc → c_util → c_pal → macro_utils_c
- `c_pal/` headers come first (highest depth, fewest dependencies)
- `c_util/` headers come second (depends on c_pal)
- `zrpc/` headers come last (depends on both c_util and c_pal)

**7. Project-Specific Headers (last):**
```c
#include "component_api.h"          // Component's own header
#include "other_project_headers.h"  // Other internal headers
```

**Test File Specific Patterns:**
For unit test files, use the `ENABLE_MOCKS` pattern between infrastructure and dependency headers:
```c
#include "c_pal/interlocked.h"  // Headers that should NOT be mocked

#define ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"   // Headers to be mocked
#include "dependency_header.h"
#undef ENABLE_MOCKS

#include "real_gballoc_hl.h"    // Real implementations
#include "component_under_test.h" // Component being tested
```

**Key principles:**
- Never change the order of `macro_utils/macro_utils.h` and `c_logging/logger.h` - they must be first in infrastructure headers
- Submodule headers follow dependency depth order: highest depth (fewest dependencies) first
- Platform abstraction (`c_pal/`) always comes before utilities (`c_util/`) which comes before external libraries (`zrpc/`, `clds/`)
- Group related headers together (all c_pal headers, then all c_util headers, etc.)
- Component's own header comes last in project-specific section
- Maintain alphabetical order within each category when possible

### Memory Management
- Use `malloc`/`free` for dynamic allocation
- Use `malloc_2()` helper for array allocations with overflow protection
- Always check allocation results and handle failures gracefully

### Pointer Casting Rules
- **Do NOT cast `void*` to other pointer types** - In C, `void*` implicitly converts to any other pointer type without a cast
- This applies specifically to:
  - **`malloc` return values**: Assign directly without casting
  - **Callback context parameters**: Assign `void* context` directly to typed pointers
- Unnecessary casts can hide bugs and reduce code clarity

```c
// CORRECT - no cast needed
MY_STRUCT* ptr = malloc(sizeof(MY_STRUCT));
MY_CONTEXT* context_ptr = context;  // void* context parameter

// INCORRECT - unnecessary casts
MY_STRUCT* ptr = (MY_STRUCT*)malloc(sizeof(MY_STRUCT));  // Don't do this
MY_CONTEXT* context_ptr = (MY_CONTEXT*)context;          // Don't do this
```

**Exception**: Casts ARE required when converting `void*` to `const` qualified pointer types (e.g., `const MY_STRUCT*`).

### Error Handling
- Use `LogError()` for error conditions with descriptive messages
- Include parameter values in error messages for debugging
- Use consistent result enum patterns across components
- **Always check function return values** or explicitly cast to `(void)` when intentionally ignoring

### Reference Counting
- Use THANDLE pattern for reference-counted objects
- Always use `THANDLE_INITIALIZE`, `THANDLE_ASSIGN`, `THANDLE_MOVE` appropriately
- Never manually manipulate reference counts

### Async Operations
- Use consistent callback patterns with context parameters
- Always provide both success and error callback paths

## Unit Testing Guidelines {#unit-testing}

### Test Function Naming Convention
`TEST_FUNCTION` names should generally follow the `when_X_then_Y` pattern to clearly express the test scenario:

**Pattern:** `when_<condition>_then_<expected_outcome>`

```c
// Follows when/then pattern
TEST_FUNCTION(when_handle_is_NULL_then_function_fails)
TEST_FUNCTION(when_malloc_fails_then_create_returns_NULL)
TEST_FUNCTION(when_all_calls_succeed_then_operation_succeeds)
TEST_FUNCTION(when_bsdl_open_complete_indicates_OK_then_user_callback_receives_OK)
TEST_FUNCTION(when_sm_exec_begin_fails_then_write_records_async_fails)
TEST_FUNCTION(when_callback_context_is_NULL_then_process_terminates)

// Alternative patterns also acceptable
TEST_FUNCTION(my_function_succeeds)  // Simple happy path
TEST_FUNCTION(my_function_fails_when_underlying_functions_fail)  // Negative tests
```

**Guidelines:**
- Use `when_` prefix to describe the precondition or trigger condition
- Use `then_` to describe the expected outcome or behavior
- Be specific about what condition triggers the behavior
- Be specific about what outcome is expected
- Simple `<function>_succeeds` naming is acceptable for straightforward happy path tests

### Test Helper Functions
Create helper functions to reduce code duplication and improve test readability.

**Naming Patterns:**
- `setup_<object>_expectations()` - Sets up expected calls for creating an object
- `setup_<scenario>_expectations()` - Sets up expected calls for a specific scenario
- `create_<state>_<object>()` - Creates an object in a specific state (e.g., `create_opened_my_object`)

```c
// Helper to set up expectations for object creation
static void setup_create_my_object_expectations(void)
{
    STRICT_EXPECTED_CALL(malloc(IGNORED_ARG));
    STRICT_EXPECTED_CALL(dependency_create());
}

// Helper to create an object and verify expectations
static MY_HANDLE create_my_object(void)
{
    setup_create_my_object_expectations();
    
    MY_HANDLE handle = my_object_create();
    ASSERT_IS_NOT_NULL(handle);
    ASSERT_ARE_EQUAL(char_ptr, umock_c_get_expected_calls(), umock_c_get_actual_calls());
    umock_c_reset_all_calls();
    return handle;
}

// Helper to create an object in opened state
static MY_HANDLE create_opened_my_object(void)
{
    MY_HANDLE handle = create_my_object();
    setup_open_my_object_expectations();
    open_my_object(handle);
    ASSERT_ARE_EQUAL(char_ptr, umock_c_get_expected_calls(), umock_c_get_actual_calls());
    umock_c_reset_all_calls();
    return handle;
}
```

**Guidelines:**
- Verify expected calls match actual calls in helpers with `ASSERT_ARE_EQUAL(char_ptr, umock_c_get_expected_calls(), umock_c_get_actual_calls())` to catch setup bugs early
- Include `umock_c_reset_all_calls()` at the end of helpers to provide clean mock state
- Use descriptive names that indicate the state of the returned object
- Combine related setup steps into single helpers to avoid repetitive patterns
- Use helpers wherever the same setup pattern appears in multiple tests
- Helpers should handle assertions for setup success (e.g., `ASSERT_IS_NOT_NULL`)

### Test File Organization
Tests should be organized by the function they test, not by arbitrary categories:

```c
// Incorrect - section comments for grouping
/* Pass-through function tests */
TEST_FUNCTION(...)

/* Callback translation tests */
TEST_FUNCTION(...)

// Correct - tests grouped by function with requirement tags
/* Tests_SRS_MODULE_42_001: [ If handle is NULL then function_a shall fail. ] */
TEST_FUNCTION(when_handle_is_NULL_then_function_a_fails)
{
    ...
}

/* Tests_SRS_MODULE_42_002: [ On success function_a shall return 0. ] */
TEST_FUNCTION(when_all_calls_succeed_then_function_a_succeeds)
{
    ...
}

/* Tests_SRS_MODULE_42_010: [ If handle is NULL then function_b shall fail. ] */
TEST_FUNCTION(when_handle_is_NULL_then_function_b_fails)
{
    ...
}
```

**Guidelines:**
- Do NOT use section comments to group tests by category
- Group tests by the function they test
- Use `Tests_SRS_*` requirement tags as the primary organization
- Keep all tests for a single function together in the file

### Precompiled Headers for Unit Tests
Test helper headers that are used across multiple tests should be included in the precompiled header file (`*_ut_pch.h`):

```c
// In my_module_ut_pch.h - shared test infrastructure
#include "my_test_fake.h"          // Test fakes used throughout
#include "common_test_helpers.h"   // Shared test utilities

// In my_module_ut.c - don't duplicate PCH includes
// The includes from PCH are already available
#include "my_module_ut_pch.h"      // PCH must be first

// Test-specific includes only
#include "special_test_helper.h"   // Only used in this file
```

**Guidelines:**
- Move frequently-used test helper includes to the PCH file
- Keep test-specific includes in the test file itself
- This improves build times and reduces include duplication
- PCH include must be the first include in the test file

### Result Variable Assignment in Tests
When testing error paths, each error path in the implementation should set the result variable explicitly. This enables line-number tracking during debugging:

```c
// In implementation - result set on each error path
if (first_check_fails)
{
    LogError("first check failed");
    result = MU_FAILURE;  // Set here for debugging line info
}
else if (second_check_fails)
{
    LogError("second check failed");
    result = MU_FAILURE;  // Set here for debugging line info
}
else
{
    result = 0;
}

// Incorrect implementation - result set once at declaration
int result = MU_FAILURE;  // Don't initialize to failure
if (first_check_fails)
{
    LogError("first check failed");
    // Missing result assignment - harder to debug
}
```

### Requirements Traceability System
The codebase uses a comprehensive requirements traceability system to ensure complete coverage and consistency between specifications, implementation, and testing.

#### Requirements Documentation Structure
- Each module has a `<module_name>_requirements.md` file in its `devdoc/` folder
- Requirements use **unique specification IDs** with the format: `SRS_<MODULE_NAME>_<author_id>_<requirement_number>`
  - `SRS` = Software Requirements Specification
  - `MODULE_NAME` = Module name in uppercase (e.g., `BSDL_ADDRESS_LIST`, `BLOCK_STORAGE`)
  - `author_id` = Two-digit author identifier (e.g., `42`, `11`, `01`)
  - `requirement_number` = Sequential three-digit number (e.g., `001`, `038`, `120`)

#### Requirement ID Examples
```
SRS_BSDL_ADDRESS_LIST_42_001
SRS_BLOCK_STORAGE_11_038
SRS_MSI_TOKEN_CACHE_01_015
```

#### Requirements Documentation Format
Requirements in `.md` files use backticks for better readability:
```markdown
**SRS_MODULE_42_001: [** If `parameter` is `NULL` then `function_name` shall fail and return a non-zero value. **]**

**SRS_MODULE_42_002: [** `function_name` shall allocate memory for the `HANDLE_TYPE` structure. **]**

**SRS_MODULE_42_003: [** If `malloc` fails then `function_name` shall return `NULL`. **]**
```

#### Code Implementation Tracing
Requirements are traced to implementation using `Codes_SRS_` comments:
```c
int module_function(void* parameter)
{
    int result;

    /*Codes_SRS_MODULE_42_001: [ If parameter is NULL then module_function shall fail and return a non-zero value. ]*/
    if (parameter == NULL)
    {
        LogError("invalid argument void* parameter=%p", parameter);
        result = MU_FAILURE;
    }
    else
    {
        /*Codes_SRS_MODULE_42_002: [ module_function shall allocate memory for the HANDLE_TYPE structure. ]*/
        HANDLE_TYPE* handle = malloc(sizeof(HANDLE_TYPE));
        /*Codes_SRS_MODULE_42_003: [ If malloc fails then module_function shall return NULL. ]*/
        if (handle == NULL)
        {
            LogError("malloc failed");
            result = MU_FAILURE;
        }
        else
        {
            // Success path
            result = 0;
        }
    }

    return result;
}
```

#### Unit Test Tracing
Requirements are traced to unit tests using `Tests_SRS_` comments. Test function names must follow the `when_X_then_Y` pattern:
```c
// Tests_SRS_MODULE_42_001: [ If parameter is NULL then module_function shall fail and return a non-zero value. ]
TEST_FUNCTION(when_parameter_is_NULL_then_module_function_fails)
{
    ///arrange

    ///act
    int result = module_function(NULL);

    ///assert
    ASSERT_ARE_NOT_EQUAL(int, 0, result);
}

// Tests_SRS_MODULE_42_002: [ module_function shall allocate memory for the HANDLE_TYPE structure. ]
// Tests_SRS_MODULE_42_003: [ If malloc fails then module_function shall return NULL. ]
TEST_FUNCTION(when_malloc_fails_then_module_function_returns_failure)
{
    ///arrange
    STRICT_EXPECTED_CALL(malloc(IGNORED_ARG))
        .SetReturn(NULL);

    ///act
    int result = module_function(&some_parameter);

    ///assert
    ASSERT_ARE_NOT_EQUAL(int, 0, result);
    ASSERT_ARE_EQUAL(char_ptr, umock_c_get_expected_calls(), umock_c_get_actual_calls());
}
```

#### Integration Test Guidelines
- **Integration tests typically do NOT use `Tests_SRS_` tagging**
- Integration tests verify end-to-end behavior rather than individual requirements
- Focus on cross-component interactions and system-level scenarios

#### Traceability Rules
1. **Unique IDs**: Each requirement must have a globally unique ID within the module
2. **Sequential Numbering**: Requirement numbers should be sequential (001, 002, 003...)
3. **Consistent Text**: The requirement specification text must be **identical** in all three places:
   - Requirements `.md` file (with backticks for readability)
   - Code implementation (`Codes_SRS_` comments - no backticks)
   - Unit test (`Tests_SRS_` comments - no backticks)
4. **Complete Coverage**: Every `SRS_` requirement should have:
   - Corresponding `Codes_SRS_` implementation tag(s)
   - Corresponding `Tests_SRS_` unit test tag(s)
5. **Traceability Tool Verification**: The build system can run `traceabilitytool` to verify complete coverage

#### Author ID Assignment
- Each developer is assigned a unique two-digit author ID
- Use your assigned ID consistently across all modules
- Contact the team lead to get your author ID assignment

#### Best Practices
- Write requirements from the caller's perspective
- Use precise language: "shall", "must", "will" for mandatory behavior
- Include error conditions and edge cases
- Group related requirements logically
- Update all three locations (spec, code, tests) when modifying requirements

These guidelines ensure consistency with the existing Azure C library ecosystem and maintain the high quality and reliability standards of the Azure Messaging Block Storage project.
