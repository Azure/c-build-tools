# Skill: Find Unnecessary Includes

## Goal
Identify and remove `#include` directives in C `.h` and `.c` files where the included header's symbols are not actually referenced by the including file.

## Scope Rules
- Only examine **first-level includes** — if `foo.c` includes `bar.h`, check whether `foo.c` directly uses symbols from `bar.h`.
- A header include in `foo.h` is unnecessary if `foo.h` does not reference any type, function, macro, or constant defined in the included header.
- A source include in `foo.c` is unnecessary if `foo.c` does not reference any symbol from the included header AND the include is not the module's own header.
- When removing an include from a `.h` file, verify that all `.c` files which previously relied on the transitive include already have a direct include, or add one if needed.

## Two-Pass Process

### Pass 1: Gather all includes
Use `grep` to extract all `#include "..."` lines from the target files:
```
grep -rn '#include "' --include="*.c" --include="*.h" <directory>
```

### Pass 2: For each include, check symbol usage

#### What a header "exports" (symbols to look for)
- `MOCKABLE_FUNCTION(, function_name, ...)` → `function_name`
- `typedef struct FOO_TAG* FOO_HANDLE;` → `FOO_HANDLE`
- `typedef struct FOO_TAG { ... } FOO;` → `FOO`
- `THANDLE_TYPE_DECLARE(FOO)` → `FOO` (used as `THANDLE(FOO)`)
- `typedef void(*CALLBACK_TYPE)(...)` → `CALLBACK_TYPE`
- `#define CONSTANT value` → `CONSTANT`
- `MU_DEFINE_ENUM(ENUM_NAME, ...)` → `ENUM_NAME` and the `_VALUES` macro
- `DEFINE_METRIC_TYPE(NAME, ...)` → `NAME`
- `TARRAY_DEFINE_STRUCT_TYPE(TYPE)` / `TARRAY_TYPE_DECLARE(TYPE)` → `TYPE`
- `DECLARE_SF_SERVICE_CONFIG(name, ...)` → `name` (used as `SF_SERVICE_CONFIG(name)`)
- Enum values inside `#define FOO_VALUES` macros → individual enum value names
- Struct field names (accessed via `->field_name`) — these are harder to detect

#### How to check usage
For each `#include "bar.h"` in file `foo.c`:
1. Read `bar.h` and extract its exported symbols.
2. Read `foo.c`, strip out all `#include` lines, and search for each symbol in the remaining content.
3. If **no symbol** from `bar.h` appears in `foo.c` (excluding the include line), the include is a candidate for removal.

## Verification Checklist

Before removing an include:

1. **Check struct member access patterns.** If `foo.c` accesses `obj->field_name` where `field_name` is a struct member defined in `bar.h`, the include IS needed even though `field_name` won't appear as a standalone symbol. This is the most common false positive.

2. **Check macro-expanded symbols.** Headers like `macro_utils.h`, `thandle.h`, `umock_c_prod.h`, and `logger.h` export symbols through complex macro chains (e.g., `THANDLE()`, `MOCKABLE_FUNCTION`, `MU_DEFINE_ENUM`, `LOGGER_LOG`). A simple text search for exported `#define` names may miss these. These infrastructure headers are almost always genuinely needed.

3. **Check `SF_SERVICE_CONFIG(name)` patterns.** The `DECLARE_SF_SERVICE_CONFIG(name, ...)` macro creates types used via `SF_SERVICE_CONFIG(name)` and `THANDLE(SF_SERVICE_CONFIG(name))`. The `name` token (e.g., `geo_replication_service`) is the link back to the declaring header. Code like `THANDLE_ASSIGN(SF_SERVICE_CONFIG(geo_replication_service))(&obj->sf_config, NULL)` requires the header that declares `SF_SERVICE_CONFIG(geo_replication_service)`. The only grep-detectable token is the bare name inside the macro call (e.g., `geo_replication_service`).

4. **Check enum value usage.** Enum values defined inside `#define FOO_VALUES` macros (e.g., `GEO_REPLICA_ROLE_PRIMARY`) are used directly in code but the symbol extraction must look inside the macro body to find them.

5. **Check transitive consumers.** Before removing an include from a `.h` file, verify that no `.c` file relies on the transitive include:
   ```
   grep -rn '#include "bar.h"' .         # who includes bar.h directly?
   grep -rn 'SYMBOL_FROM_BAR' <files>    # who uses symbols from bar.h?
   ```
   If a `.c` file uses symbols from `bar.h` but only gets them via `foo.h → bar.h`, you must add a direct include to that `.c` file.

6. **Check for duplicate includes.** While scanning, also flag cases where the same header is included twice in the same file.

## Known Limitations

- **Deps/infrastructure headers** (`c_pal/`, `c_util/`, `c_logging/`, `macro_utils/`, `umock_c/`) use heavy macro metaprogramming. Automated symbol extraction produces many false positives for these. Manual verification is required, or use a compiler-based tool like `include-what-you-use`.
- **IDL-generated headers** may re-export symbols from other headers in ways that are hard to trace.
- **COM wrapper patterns** generate symbols through macro expansion that simple regex can't detect.

## After Making Changes

1. **Build the project** to verify no compilation errors.
2. **Build downstream consumers** (other modules that include the modified headers) to catch transitive breakage.
3. Verify the diff is minimal — only `#include` line removals, no other changes.
