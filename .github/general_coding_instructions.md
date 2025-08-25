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
- **Prefix internal functions with the module name and `internal`**:
  - Pattern: `<module_prefix>_internal_<action>[_<qualifier>]`
  - Examples:
    - `static int bsdl_internal_validate_parameters(...)`
    - `static void bs_internal_cleanup_resources(...)`
    - `static RESULT_TYPE sf_internal_process_callback(...)`
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
- **Internal Functions**: `*_internal_*()` prefix for static, non-public functions

### Function Visibility Rules
- **Public API functions**: Declared in header files, no `static` keyword, follow public naming conventions
- **Internal functions**: Must be `static`, prefixed with `*_internal_`, not declared in public headers
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
- Use `LogError()` to log validation failures with parameter values
- Group related validations in single `if` statement with `||` operator
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
        if (start_async_operation() == 0)
        {
            result = 0;  // Success path sets result
            goto callback_will_come;
        }
        else
        {
            result = MU_FAILURE;  // Async start failure sets result
        }
    }
    
    // Synchronous error path - call callback immediately
    callback(context, ERROR_RESULT);
    
callbackwillcome:
    return result;
}
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
For functions that need to be mocked in unit tests, use `MOCKABLE_FUNCTION` in header files:

```c
// In header file (e.g., my_module.h)
#include "umock_c/umock_c.h"

// Mockable function declaration
MOCKABLE_FUNCTION(, int, my_module_function, int, param1, const char*, param2);

// In implementation file (e.g., my_module.c)
int my_module_function(int param1, const char* param2)
{
    // Implementation
    return 0;
}
```

**MOCKABLE_FUNCTION Rules:**
- **Use for external dependencies**: Mock functions that your module calls from other modules
- **Use for testable isolation**: Mock functions to isolate the unit under test
- **Include umock_c header**: Always include `umock_c/umock_c.h` when using MOCKABLE_FUNCTION
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
Requirements are traced to unit tests using `Tests_SRS_` comments:
```c
// Tests_SRS_MODULE_42_001: [ If parameter is NULL then module_function shall fail and return a non-zero value. ]
TEST_FUNCTION(module_function_with_NULL_parameter_fails)
{
    // arrange
    // act
    int result = module_function(NULL);
    
    // assert
    ASSERT_ARE_NOT_EQUAL(int, 0, result);
}

// Tests_SRS_MODULE_42_002: [ module_function shall allocate memory for the HANDLE_TYPE structure. ]
// Tests_SRS_MODULE_42_003: [ If malloc fails then module_function shall return NULL. ]
TEST_FUNCTION(module_function_when_malloc_fails_returns_failure)
{
    // arrange
    STRICT_EXPECTED_CALL(malloc(IGNORED_ARG))
        .SetReturn(NULL);
        
    // act
    int result = module_function(&some_parameter);
    
    // assert
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
