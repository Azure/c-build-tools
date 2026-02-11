# Skill: Find Unnecessary Includes

## Goal
Identify and remove `#include` directives in C `.h` and `.c` files where the included header's symbols are not actually referenced by the including file.

## Scope Rules
- Only examine **first-level includes** — if `foo.c` includes `bar.h`, check whether `foo.c` directly uses symbols from `bar.h`.
- Do NOT remove an include just because the same header is transitively included by another header. Each file should explicitly include what it directly uses — transitive includes are not a reason for removal.
- A header include in `foo.h` is unnecessary if `foo.h` does not reference any type, function, macro, or constant defined in the included header.
- A source include in `foo.c` is unnecessary if `foo.c` does not reference any symbol from the included header AND the include is not the module's own header.
- When removing an include from a `.h` file, verify that all `.c` files which previously relied on the transitive include already have a direct include, or add one if needed.
- Only examine source files **outside** of `deps/`. Do not validate includes within deps code itself.
- **DO** check whether non-deps files are correctly including deps headers (remove unnecessary deps includes).

## Deps Header Classification

Not all deps headers are equal. Some are pure macro infrastructure where automated symbol detection is impossible. Others export concrete types and functions that are easily searchable. Classify deps headers before analyzing:

### Skip List — Do Not Analyze (macro-heavy, almost always necessary)
These headers export their functionality through complex macro expansions that cannot be detected by text search. If a file includes one of these, **skip it** — do not flag it as a candidate for removal.

Any header NOT on this skip list should be treated as analyzable by default.

| Header | Why it's macro-heavy |
|--------|---------------------|
| `macro_utils/macro_utils.h` | `MU_DEFINE_ENUM`, `MU_ENUM_VALUE`, `MU_C2`, `MU_FOR_EACH_2`, `PRI_MU_ENUM`, `MU_FAILURE` — pervasive macro metaprogramming |
| `c_pal/thandle.h` | `THANDLE()`, `THANDLE_ASSIGN()`, `THANDLE_INITIALIZE()`, `THANDLE_INITIALIZE_MOVE()`, `THANDLE_MOVE()`, `THANDLE_TYPE_DEFINE()`, `THANDLE_TYPE_DECLARE()` |
| `c_pal/thandle_ll.h` | Low-level THANDLE macros: `THANDLE_LL_TYPE_DEFINE()`, `THANDLE_LL_TYPE_DECLARE()`, the `THANDLE()` typedef itself |
| `c_pal/thandle_ptr.h` | `PTR()`, `THANDLE_PTR_DECLARE()`, `THANDLE_PTR_DEFINE()`, `THANDLE_PTR_CREATE_WITH_MOVE()` |
| `c_pal/thandle_log_context_handle.h` | Declares `THANDLE_PTR(LOG_CONTEXT_HANDLE)` — all macro-based |
| `c_pal/gballoc_hl.h` | `gballoc_hl_malloc`, `gballoc_hl_free` etc. — used via redirect macros, always needed with `gballoc_hl_redirect.h` |
| `c_pal/gballoc_hl_redirect.h` | `#define malloc gballoc_hl_malloc`, `#define free gballoc_hl_free` — pure macro redirects, no searchable symbols |
| `c_logging/logger.h` | `LOGGER_LOG`, `LogError`, `LogInfo`, `LogWarning`, `LogCritical`, `LogVerbose` — all macro-based |
| `c_pal/log_critical_and_terminate.h` | `LogCriticalAndTerminate` macro |
| `umock_c/umock_c_prod.h` | `MOCKABLE_FUNCTION`, `MOCKABLE_FUNCTION_WITH_RETURNS` — wraps all function declarations in deps headers |
| `c_pal/containing_record.h` | `CONTAINING_RECORD` macro |
| `c_pal/interlocked.h` | `interlocked_add`, `interlocked_compare_exchange`, `interlocked_increment` etc. — all via `MOCKABLE_FUNCTION` plus `volatile_atomic` macro |
| `com_wrapper/com_wrapper.h` | `DEFINE_COM_WRAPPER_OBJECT()`, `COM_WRAPPER_CREATE()`, `IMPLEMENT_COM_WRAPPER_TYPE_CREATE_COMMON()` — heavy code generation macros |
| `sf_c_util/sf_service_config.h` | `DECLARE_SF_SERVICE_CONFIG()`, `SF_SERVICE_CONFIG()` — generates types via macro expansion |
| `c_util/tarray.h` | `TARRAY()`, `TARRAY_CREATE_DECLARE()`, `TARRAY_CREATE_DEFINE()` — macro-based generic array |
| `c_util/tarray_ll.h` | Low-level TARRAY macros: `TARRAY_LL()`, `TARRAY_DEFINE_STRUCT_TYPE()` |
| `c_util/sync_wrapper.h` | `SYNC_WRAPPER_RESULT`, async-to-sync wrapper generation macros |
| `zrpc/zrpc_idl.h` | IDL code generation macros for RPC stubs — massive macro expansion |
| `zrpc/zrpc_struct.h` | `ZRPC_STRUCT_FIELD()`, struct serialization macros |
| `zrpc/zrpc_enum.h` | `DECLARE_ZRPC_ENUM_TYPE()` — macro-based enum serialization |
| `sf_c_util/fc_activation_context_com.h` | `FC_ACTIVATION_CONTEXT_HANDLE_INTERFACES` — COM interface generation macro |
| `sf_c_util/servicefabric_enums_to_strings.h` | Pure macro-based enum-to-string conversions |
| `c_util/constbuffer_array_sync_wrapper.h` | Sync wrapper generation macro |
| `umock_c/umock_c.h` | Test framework setup macros |
| `umock_c/umock_c_negative_tests.h` | Negative test framework macros |
| `umock_c/umock_c_ENABLE_MOCKS.h` | Mock enablement macros |
| `umock_c/umock_c_DISABLE_MOCKS.h` | Mock disablement macros |
| `umock_c/umocktypes_stdint.h` | Mock type registration for stdint types |
| `umock_c/umocktypes_bool.h` | Mock type registration for bool |
| `umock_c/umocktypes_charptr.h` | Mock type registration for char* |
| `umock_c/umocktypes_wcharptr.h` | Mock type registration for wchar_t* |
| `umock_c/umocktypes_windows.h` | Mock type registration for Windows types |
| `umock_c/umocktypes.h` | Base mock type registration |

### Analyzable List — Known Searchable Headers (reference)
These headers export concrete types, functions, structs, enums, or simple `#define` constants that CAN be detected by grepping for their symbol names. This list is provided as a reference for key searchable symbols — but **any header not on the skip list should be analyzed the same way**, even if not listed here.

| Header | Key searchable symbols |
|--------|----------------------|
| `c_util/rc_string.h` | `RC_STRING`, `RC_STRING_VALUE`, `RC_STRING_AS_CHARPTR`, `RC_STRING_FREE_FUNC` |
| `c_util/constbuffer_array.h` | `CONSTBUFFER_ARRAY_HANDLE`, `constbuffer_array_create`, `constbuffer_array_get_buffer_count` |
| `c_util/constbuffer.h` | `CONSTBUFFER_HANDLE`, `CONSTBUFFER`, `CONSTBUFFER_WRITABLE_HANDLE`, `constbuffer_create` |
| `c_util/doublylinkedlist.h` | `DLIST_ENTRY`, `PDLIST_ENTRY`, `DList_InitializeListHead`, `DList_InsertTailList`, `DList_IsListEmpty` |
| `c_util/channel.h` | `CHANNEL`, `CHANNEL_RESULT`, `ON_DATA_AVAILABLE_CB`, `ON_DATA_CONSUMED_CB` |
| `c_util/async_op.h` | `ASYNC_OP`, `ASYNC_OP_STATE`, `ASYNC_OP_CANCEL_IMPL`, `async_op_create` |
| `c_util/rc_ptr.h` | `RC_PTR`, `RC_PTR_VALUE`, `RC_PTR_FREE_FUNC`, `rc_ptr_create_with_move_pointer` |
| `c_util/memory_data.h` | `read_uint8_t`, `read_uint16_t`, `read_uint32_t`, `write_uint8_t`, `write_uint16_t` |
| `c_util/for_each_in_folder.h` | `ON_EACH_IN_FOLDER`, `for_each_in_folder` |
| `c_util/object_lifetime_tracker.h` | `OBJECT_LIFETIME_TRACKER_HANDLE`, `object_lifetime_tracker_create`, `KEY_MATCH_FUNCTION_RESULT` |
| `c_util/rc_string_array.h` | `RC_STRING_ARRAY`, `rc_string_array_create`, `rc_string_array_destroy` |
| `c_pal/sm.h` | `SM_HANDLE`, `SM_RESULT`, `sm_create`, `sm_open_begin`, `sm_exec_begin`, `sm_close_begin` |
| `c_pal/threadpool.h` | `THREADPOOL`, `THREADPOOL_WORK_FUNCTION`, `THREADPOOL_TIMER`, `THREADPOOL_WORK_ITEM` |
| `c_pal/threadapi.h` | `THREAD_HANDLE`, `THREADAPI_RESULT`, `ThreadAPI_Create`, `ThreadAPI_Join`, `ThreadAPI_Sleep` |
| `c_pal/execution_engine.h` | `EXECUTION_ENGINE_HANDLE`, `EXECUTION_ENGINE_PARAMETERS`, `execution_engine_create` |
| `c_pal/string_utils.h` | `sprintf_char`, `vsprintf_char`, `mbs_to_wcs`, `wcs_to_mbs` |
| `c_pal/interlocked_hl.h` | `INTERLOCKED_HL_RESULT`, `InterlockedHL_Add64WithCeiling`, `InterlockedHL_WaitForValue`, `InterlockedHL_SetAndWake` |
| `c_pal/uuid.h` | `UUID_T`, `uuid_produce`, `is_uuid_nil`, `uuid_from_GUID`, `UUID_T_IS_EQUAL` |
| `c_pal/sync.h` | `WAIT_ON_ADDRESS_RESULT`, `wait_on_address`, `wake_by_address_all`, `wake_by_address_single` |
| `c_pal/srw_lock.h` | `SRW_LOCK_HANDLE`, `srw_lock_create`, `srw_lock_acquire_exclusive`, `srw_lock_release_exclusive` |
| `c_pal/srw_lock_ll.h` | `SRW_LOCK_LL`, `srw_lock_ll_init`, `srw_lock_ll_acquire_exclusive` |
| `c_pal/timer.h` | `timer_global_get_elapsed_us` |
| `c_pal/platform.h` | `platform_init`, `platform_deinit` |
| `c_pal/s_list.h` | `S_LIST_ENTRY`, `PS_LIST_ENTRY`, `s_list_initialize`, `S_LIST_MATCH_FUNCTION` |
| `c_pal/lazy_init.h` | `LAZY_INIT_RESULT`, `LAZY_INIT_NOT_DONE`, `lazy_init` |
| `c_pal/async_socket.h` | `ASYNC_SOCKET_HANDLE`, `ASYNC_SOCKET_OPEN_RESULT`, `ASYNC_SOCKET_SEND_RESULT` |
| `c_pal/ps_util.h` | `ps_util_terminate_process`, `ps_util_exit_process` |
| `c_pal/job_object_helper.h` | `JOB_OBJECT_HELPER`, `job_object_helper_set_job_limits_to_current_process` |
| `c_logging/log_context.h` | `LOG_CONTEXT_HANDLE`, `LOG_CONTEXT_TAG` (but note: also has `LOG_CONTEXT_STRING_PROPERTY` macros) |
| `clds/lock_free_set.h` | `LOCK_FREE_SET_HANDLE`, `LOCK_FREE_SET_ITEM`, `lock_free_set_create`, `lock_free_set_insert` |
| `sf_c_util/hresult_to_string.h` | `HRESULT_TO_STRING`, `same_as_free`, `same_as_malloc` |
| `sf_c_util/fc_activation_context.h` | `FC_ACTIVATION_CONTEXT_HANDLE`, `fc_activation_context_create`, `get_ContextId` |
| `sf_c_util/configuration_reader.h` | `configuration_reader_get_uint8_t`, `configuration_reader_get_uint32_t`, `configuration_reader_get_uint64_t` |
| `sf_c_util/fabric_op_completed_sync_ctx.h` | `FABRIC_OP_COMPLETED_SYNC_CTX_HANDLE`, `fabric_op_completed_sync_ctx_create` |
| `sf_c_util/fabric_string_result.h` | `FABRIC_STRING_RESULT_HANDLE`, `fabric_string_result_create`, `fabric_string_result_get_String` |
| `sf_c_util/common_argc_argv.h` | `ARGC_ARGV_DATA_RESULT`, `CONFIGURATION_PACKAGE_NAME`, `SECTION_NAME_DEFINE` |
| `azure_messaging_metrics/azure_messaging_metric_context.h` | `AZURE_MESSAGING_METRIC_CONTEXT_HANDLE`, `azure_messaging_metric_context_create` |
| `azure_messaging_metrics/azure_messaging_metric.h` | `AZURE_MESSAGING_METRIC_HANDLE`, `azure_messaging_metric_create`, `azure_messaging_metric_log` |
| `zrpc/substream_factory.h` | `SUBSTREAM_FACTORY`, `SUBSTREAM_MODE` |
| `zrpc/zrpc.h` | `ZRPC_REQUEST_COMPLETE_RESULT`, `ON_ZRPC_HANDLE_REQUEST`, `ON_ZRPC_REQUEST_COMPLETE` |
| `zrpc/zrpc_server.h` | `ZRPC_SERVER_HANDLE`, `ZRPC_CONNECTED_CLIENT_HANDLE`, `ZRPC_SERVER_OPEN_RESULT` |
| `zrpc/zrpc_client.h` | `ZRPC_CLIENT_HANDLE`, `ZRPC_CLIENT_OPEN_RESULT`, `ON_ZRPC_CLIENT_OPEN_COMPLETE` |
| `zrpc/zrpc_client_io_config.h` | `ZRPC_CLIENT_IO_CONFIG`, `zrpc_client_io_create_parameters` |
| `zrpc/zrpc_tcp_client_io.h` | `zrpc_tcp_client_io_get_interface_description`, `ZRPC_IO_INTERFACE_DESCRIPTION` |
| `zrpc/zrpc_tls_client_io.h` | `zrpc_tls_client_io_get_interface_description` |
| `zrpc/zrpc_tls_client_io_config.h` | `ZRPC_TLS_CLIENT_IO_CONFIG`, `zrpc_tls_client_io_config_create` |
| `zrpc/zrpc_io_config_wrapper.h` | `ZRPC_IO_CONFIG_WRAPPER`, `zrpc_io_config_wrapper_create_from_tcp_client` |
| `zrpc/zrpc_type_constbuffer_array.h` | `zrpc_type_to_value_CONSTBUFFER_ARRAY_HANDLE`, `zrpc_type_from_value_CONSTBUFFER_ARRAY_HANDLE` |
| `zrpc/zrpc_basic_types.h` | `ascii_char_ptr`, `zrpc_type_to_value_bool`, `zrpc_type_from_value_bool` |
| `zrpc/queue_processor.h` | `QUEUE_PROCESSOR_HANDLE`, `queue_processor_create` |
| `zrpc/zrpc_cuid.h` | `ZRPC_CUID`, `PRI_ZRPC_CUID` |
| `zrpc/zrpc_socket_listener_config.h` | `ZRPC_SOCKET_LISTENER_CONFIG`, `zrpc_tcp_listener_create_parameters` |
| `zrpc/get_certificate.h` | `CERTIFICATE_QUERY_TYPE`, `CERTIFICATE_USAGE_TYPE` |
| `zrpc/get_certificate_thandle_wrapper.h` | `GET_CERTIFICATE_WRAPPER`, `get_certificate_wrapper_create_with_move` |
| `zrpc/factory_client_certificate_by_name.h` | `factory_client_certificate_by_name` |
| `zrpc/server_certificate_find.h` | `SERVER_CERTIFICATE_FIND`, `server_certificate_find_create` |
| `zrpc/zrpc_tcp_listener.h` | `zrpc_tcp_listener_get_interface_description` |
| `zrpc/zrpc_tls_listener.h` | `zrpc_tls_listener_get_interface_description` |
| `zrpc/zrpc_correlator.h` | `ZRPC_CORRELATOR_HANDLE`, `ZRPC_CORRELATION_ID`, `ZRPC_CORRELATOR_SEND_REQUEST_RESULT` |
| `zrpc/substream.h` | `SUBSTREAM_HANDLE`, `SUBSTREAM_OPEN_RESULT`, `SUBSTREAM_SEND_RESULT` |
| `c_pal/umocktypes_uuid_t.h` | Mock type registration for UUID_T |

## Two-Pass Process

### Pass 1: Gather all includes
Use `grep` to extract all `#include "..."` lines from the target files (non-deps only):
```
grep -rn '#include "' --include="*.c" --include="*.h" <directory> | grep -v deps/
```

### Pass 2: For each include, check symbol usage

First, check the included header against the **Skip List** above. If it's on the skip list, move on — do not flag it.

For all other includes (project headers and **Analyzable List** deps headers):

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

2. **Check macro-expanded symbols.** Even for analyzable headers, some symbols are used indirectly through macro expansion. For example, `MU_DEFINE_ENUM(ENUM_NAME, ENUM_NAME_VALUES)` makes the `_VALUES` macro necessary. Check for indirect references before removing.

3. **Check `SF_SERVICE_CONFIG(name)` patterns.** The `DECLARE_SF_SERVICE_CONFIG(name, ...)` macro creates types used via `SF_SERVICE_CONFIG(name)` and `THANDLE(SF_SERVICE_CONFIG(name))`. The `name` token (e.g., `geo_replication_service`) is the link back to the declaring header. Code like `THANDLE_ASSIGN(SF_SERVICE_CONFIG(geo_replication_service))(&obj->sf_config, NULL)` requires the header that declares `SF_SERVICE_CONFIG(geo_replication_service)`. The only grep-detectable token is the bare name inside the macro call (e.g., `geo_replication_service`).

4. **Check enum value usage.** Enum values defined inside `#define FOO_VALUES` macros (e.g., `GEO_REPLICA_ROLE_PRIMARY`) are used directly in code but the symbol extraction must look inside the macro body to find them.

5. **Check transitive consumers.** Before removing an include from a `.h` file, verify that no `.c` file relies on the transitive include:
   ```
   grep -rn '#include "bar.h"' .         # who includes bar.h directly?
   grep -rn 'SYMBOL_FROM_BAR' <files>    # who uses symbols from bar.h?
   ```
   If a `.c` file uses symbols from `bar.h` but only gets them via `foo.h → bar.h`, you must add a direct include to that `.c` file.

6. **Check for duplicate includes.** While scanning, also flag cases where the same header is included twice in the same file.

## After Making Changes

1. **Build the project** to verify no compilation errors.
2. **Build downstream consumers** (other modules that include the modified headers) to catch transitive breakage.
3. Verify the diff is minimal — only `#include` line removals, no other changes.
