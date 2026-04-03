// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::collections::HashMap;
use std::fs;

pub struct SrsConsistency {
    /// Markdown requirements: tag -> MarkdownReq
    md_requirements: HashMap<String, MarkdownReq>,
    /// Collected C tags for later comparison
    c_tags_collected: Vec<CollectedCTag>,
    /// Tag placement violations
    placement_violations: Vec<PlacementViolation>,
    /// Total requirements found in markdown
    total_md_requirements: i32,
    /// C files scanned
    c_files_scanned: i32,
}

#[allow(dead_code)]
struct MarkdownReq {
    clean_text: String,
    file_path: String,
}

#[allow(dead_code)]
struct CollectedCTag {
    tag: String,
    prefix: String,
    text: String,
    original_match: String,
    match_index: usize,
    has_duplication: bool,
    is_incomplete: bool,
    c_file_path: String,
    c_file_relative: String,
}

struct PlacementViolation {
    file_path: String,
    full_tag: String,
    violation: String,
}

struct InconsistencyRecord {
    tag: String,
    c_file: String,
    c_text: String,
    md_text: String,
    original_match: String,
    match_index: usize,
}

impl SrsConsistency {
    pub fn new() -> Self {
        Self {
            md_requirements: HashMap::new(),
            c_tags_collected: Vec::new(),
            placement_violations: Vec::new(),
            total_md_requirements: 0,
            c_files_scanned: 0,
        }
    }
}

/// Strip markdown formatting from text:
/// - Remove bold **text**
/// - Remove italics *word* (but not C pointer *ptr syntax)
/// - Remove backticks `text`
/// - Unescape markdown: \< -> <, \> -> >, \\ -> \, etc.
/// - Normalize whitespace
fn strip_markdown_formatting(text: &str) -> String {
    let mut result = text.to_string();

    // Remove bold markers (**text**) - loop to handle nested
    loop {
        if let Some(start) = result.find("**") {
            if let Some(end) = result[start + 2..].find("**") {
                let inner = result[start + 2..start + 2 + end].to_string();
                result = format!("{}{}{}", &result[..start], inner, &result[start + 2 + end + 2..]);
                continue;
            }
        }
        break;
    }

    // Remove italics *word* - only match word boundaries (not C pointers)
    // Pattern: *(\w+)* where surrounding context suggests it's italic, not pointer
    let mut new_result = String::with_capacity(result.len());
    let chars: Vec<char> = result.chars().collect();
    let clen = chars.len();
    let mut i = 0;
    while i < clen {
        if chars[i] == '*' && i + 1 < clen && chars[i + 1].is_alphanumeric() {
            // Look for closing * after word chars
            let word_start = i + 1;
            let mut j = word_start;
            while j < clen && (chars[j].is_alphanumeric() || chars[j] == '_') {
                j += 1;
            }
            if j < clen && chars[j] == '*' && j > word_start {
                // This is *word* pattern - remove the asterisks
                for k in word_start..j {
                    new_result.push(chars[k]);
                }
                i = j + 1;
                continue;
            }
        }
        new_result.push(chars[i]);
        i += 1;
    }
    result = new_result;

    // Remove backticks `text`
    let mut new_result = String::with_capacity(result.len());
    let chars: Vec<char> = result.chars().collect();
    let clen = chars.len();
    let mut i = 0;
    while i < clen {
        if chars[i] == '`' {
            let start = i + 1;
            let mut j = start;
            while j < clen && chars[j] != '`' {
                j += 1;
            }
            if j < clen {
                // Found matching backtick
                for k in start..j {
                    new_result.push(chars[k]);
                }
                i = j + 1;
                continue;
            }
        }
        new_result.push(chars[i]);
        i += 1;
    }
    result = new_result;

    // Unescape markdown: \X -> X for any character
    let mut new_result = String::with_capacity(result.len());
    let bytes = result.as_bytes();
    let blen = bytes.len();
    let mut i = 0;
    while i < blen {
        if bytes[i] == b'\\' && i + 1 < blen {
            new_result.push(bytes[i + 1] as char);
            i += 2;
        } else {
            new_result.push(bytes[i] as char);
            i += 1;
        }
    }
    result = new_result;

    // Normalize whitespace
    let parts: Vec<&str> = result.split_whitespace().collect();
    parts.join(" ")
}

/// Extract SRS tags from markdown content.
/// Pattern: **SRS_MODULE_DD_DDD: [** text **]**
fn extract_markdown_srs_tags(content: &str, file_path: &str) -> Vec<(String, MarkdownReq)> {
    let mut tags = Vec::new();

    // Use byte scanning to find the pattern
    let bytes = content.as_bytes();
    let len = bytes.len();
    let mut p = 0usize;

    while p + 10 < len {
        // Find "**SRS_"
        if p + 6 < len
            && bytes[p] == b'*'
            && bytes[p + 1] == b'*'
            && bytes[p + 2] == b'S'
            && bytes[p + 3] == b'R'
            && bytes[p + 4] == b'S'
            && bytes[p + 5] == b'_'
        {
            let tag_start = p + 2; // Start of "SRS_"
            let mut q = p + 6;

            // Scan tag chars (uppercase letters, digits, underscore)
            while q < len && is_srs_tag_char(bytes[q]) {
                q += 1;
            }

            let tag_end = q;

            // Expect ':' immediately (no whitespace - matching PS1 regex behavior)
            if q >= len || bytes[q] != b':' {
                p += 2;
                continue;
            }
            q += 1;

            // Validate tag format: SRS_MODULE_DD_DDD
            let tag_bytes = &bytes[tag_start..tag_end];
            if !validate_srs_tag_format(tag_bytes) {
                p += 2;
                continue;
            }

            // Skip whitespace
            while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                q += 1;
            }

            // Expect "[**"
            if q + 3 > len || bytes[q] != b'[' || bytes[q + 1] != b'*' || bytes[q + 2] != b'*' {
                p += 2;
                continue;
            }
            q += 3;

            // Skip whitespace after [**
            while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                q += 1;
            }

            // Find "**]**" ending - don't cross newlines (matching PS1 regex behavior)
            let text_start = q;
            let mut text_end = None;
            while q + 5 <= len {
                // Stop at newlines
                if bytes[q] == b'\n' || bytes[q] == b'\r' {
                    break;
                }
                if bytes[q] == b'*'
                    && bytes[q + 1] == b'*'
                    && bytes[q + 2] == b']'
                    && bytes[q + 3] == b'*'
                    && bytes[q + 4] == b'*'
                {
                    text_end = Some(q);
                    break;
                }
                q += 1;
            }

            if let Some(te) = text_end {
                // Trim trailing whitespace from text
                let mut actual_end = te;
                while actual_end > text_start && (bytes[actual_end - 1] == b' ' || bytes[actual_end - 1] == b'\t') {
                    actual_end -= 1;
                }

                let tag = String::from_utf8_lossy(&bytes[tag_start..tag_end]).to_string();
                let raw_text = String::from_utf8_lossy(&bytes[text_start..actual_end]).to_string();
                let clean_text = strip_markdown_formatting(&raw_text);

                tags.push((tag, MarkdownReq {
                    clean_text,
                    file_path: file_path.to_string(),
                }));

                p = te + 5;
            } else {
                p += 2;
            }
        } else {
            p += 1;
        }
    }

    tags
}

fn is_srs_tag_char(b: u8) -> bool {
    (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') || b == b'_'
}

/// Validate tag has format SRS_MODULE_DD_DDD (ends with _NN_NNN)
fn validate_srs_tag_format(tag: &[u8]) -> bool {
    let len = tag.len();
    if len < 11 {
        // SRS_ + at least 1 char module + _DD_DDD = 11+
        return false;
    }
    // Check ends with _DD_DDD
    len >= 11
        && tag[len - 1].is_ascii_digit()
        && tag[len - 2].is_ascii_digit()
        && tag[len - 3].is_ascii_digit()
        && tag[len - 4] == b'_'
        && tag[len - 5].is_ascii_digit()
        && tag[len - 6].is_ascii_digit()
        && tag[len - 7] == b'_'
}

struct CTag {
    tag: String,
    prefix: String,
    text: String,
    original_match: String,
    match_index: usize,
    has_duplication: bool,
    is_incomplete: bool,
}

/// Extract SRS tags from C code.
/// Handles block comments, incomplete block comments, and line comments.
fn extract_c_srs_tags(content: &str) -> Vec<CTag> {
    let mut tags = Vec::new();
    let mut complete_ranges: Vec<(usize, usize)> = Vec::new();

    // Phase 1: Find complete block comments: /*..Codes/Tests_SRS_MODULE_DD_DDD: [ text ]*/
    let bytes = content.as_bytes();
    let len = bytes.len();

    // Find block comments
    {
        let mut p = 0usize;
        while p + 2 < len {
            if bytes[p] == b'/' && bytes[p + 1] == b'*' {
                let comment_start = p;
                // Skip additional * chars
                let mut q = p + 2;
                while q < len && bytes[q] == b'*' {
                    q += 1;
                }
                // Skip whitespace
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Check for Codes_ or Tests_ prefix
                let prefix = if q + 6 <= len && &bytes[q..q + 6] == b"Codes_" {
                    q += 6;
                    "Codes"
                } else if q + 6 <= len && &bytes[q..q + 6] == b"Tests_" {
                    q += 6;
                    "Tests"
                } else {
                    p += 1;
                    continue;
                };

                // Expect "SRS_"
                if q + 4 > len || &bytes[q..q + 4] != b"SRS_" {
                    p += 1;
                    continue;
                }
                let tag_start = q; // Start of SRS_
                q += 4;

                // Scan tag chars
                while q < len && is_srs_tag_char(bytes[q]) {
                    q += 1;
                }
                let tag_end = q;

                // Validate tag format
                let tag_bytes = &bytes[tag_start..tag_end];
                if !validate_srs_tag_format(tag_bytes) {
                    p += 1;
                    continue;
                }

                // Skip optional whitespace before colon
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Expect ':'
                if q >= len || bytes[q] != b':' {
                    p += 1;
                    continue;
                }
                q += 1;

                // Skip whitespace
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Expect '['
                if q >= len || bytes[q] != b'[' {
                    p += 1;
                    continue;
                }
                q += 1;

                // Skip whitespace after [
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }
                let actual_text_start = q;

                // Scan for ]*/ (complete) on the same line
                // Limit scanning to same line
                let line_end = find_line_end(bytes, q);

                // Look for ] followed by optional whitespace and */
                let mut found_complete = false;
                let mut found_incomplete = false;
                let mut text_end_pos = q;
                let mut comment_end_pos = q;

                // Search for ]*/  or just */ (incomplete)
                let mut scan = q;
                while scan < line_end {
                    if bytes[scan] == b']' {
                        // Found ], look for */ after optional whitespace
                        let mut after_bracket = scan + 1;
                        while after_bracket < line_end && (bytes[after_bracket] == b' ' || bytes[after_bracket] == b'\t') {
                            after_bracket += 1;
                        }
                        // Check for */ (possibly with extra *)
                        if after_bracket + 1 < len && bytes[after_bracket] == b'*' && bytes[after_bracket + 1] == b'/' {
                            text_end_pos = scan;
                            comment_end_pos = after_bracket + 2;
                            found_complete = true;
                            // Don't break - keep looking for LAST ]*/ on this line
                        } else if after_bracket + 2 < len && bytes[after_bracket] == b'*' && bytes[after_bracket + 1] == b'*' && bytes[after_bracket + 2] == b'/' {
                            text_end_pos = scan;
                            comment_end_pos = after_bracket + 3;
                            found_complete = true;
                        }
                    }
                    scan += 1;
                }

                if !found_complete {
                    // Look for incomplete: text followed by */ without ]
                    // PS1 incomplete pattern requires text to NOT contain ']'
                    scan = q;
                    let mut has_bracket_in_text = false;
                    while scan + 1 < line_end {
                        if bytes[scan] == b']' {
                            has_bracket_in_text = true;
                        }
                        if bytes[scan] == b'*' && bytes[scan + 1] == b'/' {
                            if !has_bracket_in_text {
                                text_end_pos = scan;
                                comment_end_pos = scan + 2;
                                found_incomplete = true;
                            }
                            break;
                        }
                        scan += 1;
                    }
                }

                if found_complete || found_incomplete {
                    let tag = String::from_utf8_lossy(&bytes[tag_start..tag_end]).to_string();

                    // Extract text: trim whitespace
                    let raw_text_bytes = &bytes[actual_text_start..text_end_pos];
                    let raw_text = String::from_utf8_lossy(raw_text_bytes).to_string();
                    let clean_text = normalize_c_text(&raw_text);

                    let original = String::from_utf8_lossy(&bytes[comment_start..comment_end_pos]).to_string();

                    // Check for duplication
                    let has_duplication = original.matches("]*/").count() > 1;

                    complete_ranges.push((comment_start, comment_end_pos));

                    tags.push(CTag {
                        tag,
                        prefix: prefix.to_string(),
                        text: clean_text,
                        original_match: original,
                        match_index: comment_start,
                        has_duplication,
                        is_incomplete: found_incomplete && !found_complete,
                    });

                    p = comment_end_pos;
                } else {
                    p += 1;
                }
            } else {
                p += 1;
            }
        }
    }

    // Phase 2: Find line comments: // Codes_SRS_MODULE_DD_DDD: [ text ]
    {
        let mut p = 0usize;
        while p + 2 < len {
            // Check if we are at start of a // comment (not inside a block comment match)
            if bytes[p] == b'/' && bytes[p + 1] == b'/' {
                let comment_start = p;
                let mut q = p + 2;

                // Skip whitespace
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Check for Codes_ or Tests_ prefix
                let prefix = if q + 6 <= len && &bytes[q..q + 6] == b"Codes_" {
                    q += 6;
                    "Codes"
                } else if q + 6 <= len && &bytes[q..q + 6] == b"Tests_" {
                    q += 6;
                    "Tests"
                } else {
                    p += 1;
                    continue;
                };

                // Expect "SRS_"
                if q + 4 > len || &bytes[q..q + 4] != b"SRS_" {
                    p += 1;
                    continue;
                }
                let tag_start = q;
                q += 4;

                // Scan tag chars
                while q < len && is_srs_tag_char(bytes[q]) {
                    q += 1;
                }
                let tag_end = q;

                if !validate_srs_tag_format(&bytes[tag_start..tag_end]) {
                    p += 1;
                    continue;
                }

                // Skip optional whitespace before colon
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Expect ':'
                if q >= len || bytes[q] != b':' {
                    p += 1;
                    continue;
                }
                q += 1;

                // Skip whitespace
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }

                // Expect '['
                if q >= len || bytes[q] != b'[' {
                    p += 1;
                    continue;
                }
                q += 1;

                // Skip whitespace
                while q < len && (bytes[q] == b' ' || bytes[q] == b'\t') {
                    q += 1;
                }
                let text_start = q;

                // Find end of line
                let line_end = find_line_end(bytes, q);

                // Find the last ] on this line
                let mut last_bracket = None;
                for i in (text_start..line_end).rev() {
                    if bytes[i] == b']' {
                        last_bracket = Some(i);
                        break;
                    }
                }

                let text_end = last_bracket.unwrap_or(line_end);

                // Check that this doesn't overlap with a block comment match
                let overlaps = complete_ranges.iter().any(|(s, e)| {
                    comment_start >= *s && comment_start < *e
                });
                if overlaps {
                    p += 1;
                    continue;
                }

                let tag = String::from_utf8_lossy(&bytes[tag_start..tag_end]).to_string();
                let raw_text = String::from_utf8_lossy(&bytes[text_start..text_end]).to_string();
                let clean_text = normalize_c_text(&raw_text);

                let original_end = if last_bracket.is_some() { text_end + 1 } else { line_end };
                let original = String::from_utf8_lossy(&bytes[comment_start..original_end]).to_string();

                tags.push(CTag {
                    tag,
                    prefix: prefix.to_string(),
                    text: clean_text,
                    original_match: original,
                    match_index: comment_start,
                    has_duplication: false,
                    is_incomplete: last_bracket.is_none(),
                });

                p = line_end;
            } else {
                p += 1;
            }
        }
    }

    tags
}

fn find_line_end(bytes: &[u8], start: usize) -> usize {
    let mut p = start;
    while p < bytes.len() && bytes[p] != b'\n' && bytes[p] != b'\r' {
        p += 1;
    }
    p
}

fn normalize_c_text(text: &str) -> String {
    let parts: Vec<&str> = text.split_whitespace().collect();
    parts.join(" ")
}

/// Determine if a file is a test file based on parent directory name ending with _ut or _int
fn is_test_file(relative_path: &str) -> bool {
    let parts: Vec<&str> = relative_path.split(|c: char| c == '/' || c == '\\').collect();
    // Check all directory components (not the filename)
    for i in 0..parts.len().saturating_sub(1) {
        let dir = parts[i];
        if dir.ends_with("_ut") || dir.ends_with("_int") {
            return true;
        }
    }
    false
}

/// Fix inconsistencies in a C file by replacing comment text to match markdown
fn fix_c_file_records(file_path: &str, inconsistencies: &[&InconsistencyRecord]) -> bool {
    let content = match fs::read_to_string(file_path) {
        Ok(c) => c,
        Err(_) => return false,
    };

    let mut result = content.clone();
    let mut fixed_count = 0;

    // Sort by match_index descending to avoid offset issues
    let mut sorted: Vec<&&InconsistencyRecord> = inconsistencies.iter().collect();
    sorted.sort_by(|a, b| b.match_index.cmp(&a.match_index));

    for inc in &sorted {
        let old_comment = &inc.original_match;
        if let Some(pos) = result.find(old_comment) {
            if let Some(new_comment) = build_fixed_comment(old_comment, &inc.md_text) {
                result = format!("{}{}{}", &result[..pos], new_comment, &result[pos + old_comment.len()..]);
                fixed_count += 1;
                println!("  [FIXED] {} in {}", inc.tag, extract_filename_str(file_path));
            }
        }
    }

    if fixed_count > 0 {
        if fs::write(file_path, &result).is_ok() {
            return true;
        }
    }
    false
}

fn extract_filename_str(path: &str) -> &str {
    if let Some(pos) = path.rfind(std::path::MAIN_SEPARATOR) {
        &path[pos + 1..]
    } else if let Some(pos) = path.rfind('/') {
        &path[pos + 1..]
    } else {
        path
    }
}

/// Build a fixed comment by replacing the text portion while preserving structure
fn build_fixed_comment(old_comment: &str, new_text: &str) -> Option<String> {
    let bytes = old_comment.as_bytes();

    // Detect comment type
    if bytes.len() >= 2 && bytes[0] == b'/' && bytes[1] == b'*' {
        // Block comment
        // Find the [ and the ] (or end)
        let bracket_open = old_comment.find('[')?;
        // Find the end: ]*/ for complete, or just */ for incomplete
        let after_bracket = &old_comment[bracket_open + 1..];

        // Check if there's a ] before */
        if let Some(bracket_close_rel) = find_last_bracket_before_end(after_bracket) {
            let bracket_close = bracket_open + 1 + bracket_close_rel;
            // Preserve whitespace after [ and before ]
            let ws_after_open = extract_leading_ws(&old_comment[bracket_open + 1..bracket_close]);
            let ws_before_close = extract_trailing_ws(&old_comment[bracket_open + 1..bracket_close]);
            let suffix = &old_comment[bracket_close..];
            Some(format!("{}[{}{}{}{}", &old_comment[..bracket_open], ws_after_open, new_text, ws_before_close, suffix))
        } else {
            // Incomplete comment - add closing bracket
            // Find */
            let end_pos = old_comment.rfind("*/")?;
            let ws_after_open = extract_leading_ws(&old_comment[bracket_open + 1..end_pos]);
            Some(format!("{}[{}{} ]{}",
                &old_comment[..bracket_open],
                ws_after_open,
                new_text,
                &old_comment[end_pos..],
            ))
        }
    } else if bytes.len() >= 2 && bytes[0] == b'/' && bytes[1] == b'/' {
        // Line comment
        let bracket_open = old_comment.find('[')?;
        let after_bracket = &old_comment[bracket_open + 1..];
        if let Some(bracket_close_rel) = after_bracket.rfind(']') {
            let bracket_close = bracket_open + 1 + bracket_close_rel;
            let ws_after_open = extract_leading_ws(&old_comment[bracket_open + 1..bracket_close]);
            let ws_before_close = extract_trailing_ws(&old_comment[bracket_open + 1..bracket_close]);
            Some(format!("{}[{}{}{}]", &old_comment[..bracket_open], ws_after_open, new_text, ws_before_close))
        } else {
            Some(format!("{}[ {} ]", &old_comment[..bracket_open], new_text))
        }
    } else {
        None
    }
}

fn find_last_bracket_before_end(s: &str) -> Option<usize> {
    // Find the last ] that is followed (eventually) by */
    let bytes = s.as_bytes();
    let len = bytes.len();
    // Find */ position
    let mut end_pos = None;
    for i in (0..len.saturating_sub(1)).rev() {
        if bytes[i] == b'*' && bytes[i + 1] == b'/' {
            end_pos = Some(i);
            break;
        }
    }

    let end_pos = end_pos?;

    // Find last ] before end_pos
    for i in (0..end_pos).rev() {
        if bytes[i] == b']' {
            return Some(i);
        }
    }
    None
}

fn extract_leading_ws(s: &str) -> &str {
    let len = s.len();
    let mut p = 0;
    while p < len {
        let b = s.as_bytes()[p];
        if b == b' ' || b == b'\t' {
            p += 1;
        } else {
            break;
        }
    }
    &s[..p]
}

fn extract_trailing_ws(s: &str) -> &str {
    let len = s.len();
    let mut p = len;
    while p > 0 {
        let b = s.as_bytes()[p - 1];
        if b == b' ' || b == b'\t' {
            p -= 1;
        } else {
            break;
        }
    }
    &s[p..]
}

impl Check for SrsConsistency {
    fn name(&self) -> &str {
        "srs_consistency"
    }

    fn description(&self) -> &str {
        "Validates SRS requirement consistency between markdown and C code"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_MD | FILE_TYPE_C
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.md_requirements.clear();
        self.c_tags_collected.clear();
        self.placement_violations.clear();
        self.total_md_requirements = 0;
        self.c_files_scanned = 0;
    }

    fn check_file(&mut self, file: &FileInfo, _config: &ValidatorConfig) {
        // Collect markdown requirements from devdoc
        if file.type_flags & FILE_TYPE_MD != 0 && file.type_flags & FILE_FLAG_IN_DEVDOC != 0 {
            let content = match std::str::from_utf8(&file.content) {
                Ok(s) => s,
                Err(_) => return,
            };

            let md_tags = extract_markdown_srs_tags(content, &file.relative_path);
            for (tag, req) in md_tags {
                if !self.md_requirements.contains_key(&tag) {
                    self.md_requirements.insert(tag, req);
                    self.total_md_requirements += 1;
                }
            }
            return;
        }

        // Collect C file tags
        if file.type_flags & FILE_TYPE_C == 0 {
            return;
        }

        self.c_files_scanned += 1;

        let content = match std::str::from_utf8(&file.content) {
            Ok(s) => s,
            Err(_) => return,
        };

        let c_tags = extract_c_srs_tags(content);
        let is_test = is_test_file(&file.relative_path);

        for ctag in c_tags {
            // Tag placement check
            if is_test && ctag.prefix == "Codes" {
                self.placement_violations.push(PlacementViolation {
                    file_path: file.relative_path.clone(),
                    full_tag: format!("{}_{}", ctag.prefix, ctag.tag),
                    violation: "Codes_SRS_ tag found in test file (should use Tests_SRS_)".to_string(),
                });
            } else if !is_test && ctag.prefix == "Tests" {
                self.placement_violations.push(PlacementViolation {
                    file_path: file.relative_path.clone(),
                    full_tag: format!("{}_{}", ctag.prefix, ctag.tag),
                    violation: "Tests_SRS_ tag found in production file (should use Codes_SRS_)".to_string(),
                });
            }

            self.c_tags_collected.push(CollectedCTag {
                tag: ctag.tag,
                prefix: ctag.prefix,
                text: ctag.text,
                original_match: ctag.original_match,
                match_index: ctag.match_index,
                has_duplication: ctag.has_duplication,
                is_incomplete: ctag.is_incomplete,
                c_file_path: file.path.clone(),
                c_file_relative: file.relative_path.clone(),
            });
        }
    }

    fn finalize(&mut self, config: &ValidatorConfig) -> i32 {
        // Now that all files have been collected, compare C tags against markdown
        let mut inconsistencies: Vec<InconsistencyRecord> = Vec::new();

        for ctag in &self.c_tags_collected {
            if let Some(md_req) = self.md_requirements.get(&ctag.tag) {
                // PS1 uses -ne which is case-insensitive in PowerShell
                let texts_match = ctag.text.eq_ignore_ascii_case(&md_req.clean_text);
                if !texts_match || ctag.has_duplication || ctag.is_incomplete {
                    inconsistencies.push(InconsistencyRecord {
                        tag: ctag.tag.clone(),
                        c_file: ctag.c_file_path.clone(),
                        c_text: ctag.text.clone(),
                        md_text: md_req.clean_text.clone(),
                        original_match: ctag.original_match.clone(),
                        match_index: ctag.match_index,
                    });
                }
            }
        }

        println!();
        println!("  SRS requirements in markdown: {}", self.total_md_requirements);
        println!("  C source files scanned: {}", self.c_files_scanned);
        println!("  Inconsistencies found: {}", inconsistencies.len());
        println!("  Tag placement violations: {}", self.placement_violations.len());

        if !inconsistencies.is_empty() {
            if config.fix_mode {
                // Group by file
                let mut by_file: HashMap<String, Vec<&InconsistencyRecord>> = HashMap::new();
                for inc in &inconsistencies {
                    by_file.entry(inc.c_file.clone()).or_default().push(inc);
                }

                let mut fixed_count = 0;
                for (file_path, incs) in &by_file {
                    if fix_c_file_records(file_path, &incs) {
                        fixed_count += incs.len();
                    }
                }
                println!("  Fixed {} inconsistencies", fixed_count);
            } else {
                for inc in &inconsistencies {
                    println!("  [ERROR] {}", inc.tag);
                    println!("          C file: {}", inc.c_file);
                    println!("          C text:  '{}'", inc.c_text);
                    println!("          MD text: '{}'", inc.md_text);
                }
            }
        }

        if !self.placement_violations.is_empty() {
            println!();
            println!("  Tag placement violations:");
            for v in &self.placement_violations {
                println!("    [ERROR] {}: {} - {}", v.file_path, v.full_tag, v.violation);
            }
        }

        let unfixed = if config.fix_mode { 0 } else { inconsistencies.len() };
        (unfixed + self.placement_violations.len()) as i32
    }
}
