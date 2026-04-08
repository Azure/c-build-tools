# Malformed Requirements

## C-comment-style closings

**SRS_MALFORMED_01_001: [** If `param` is `NULL`, the function shall fail. ]*/

**SRS_MALFORMED_01_002: [** The function shall allocate memory. ]*/

## Missing trailing **

**SRS_MALFORMED_01_003: [** On success, the function shall return zero. **]

## Missing bold opening bracket

**SRS_MALFORMED_01_004: [ If `handle` is `NULL`, the function shall fail and return `NULL`. **]**

## Mixed malformations

* **SRS_MALFORMED_01_005: [** The function shall call `do_work`. ]*/)

**SRS_MALFORMED_01_006: [** If any error occurs, the function shall return a non-zero value. **]*

## Gratuitous multi-line (closing on separate line with no content between)

**SRS_MALFORMED_01_007: [** The function shall return zero.
**]**

**SRS_MALFORMED_01_008: [** The function shall allocate memory.

**]**
