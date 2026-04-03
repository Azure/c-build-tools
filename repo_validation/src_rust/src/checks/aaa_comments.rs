// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::collections::HashMap;

pub struct AaaComments {
    violations: i32,
    total_test_functions: i32,
    exempted_tests: i32,
}

impl AaaComments {
    pub fn new() -> Self {
        Self {
            violations: 0,
            total_test_functions: 0,
            exempted_tests: 0,
        }
    }
}

struct LineIndex {
    starts: Vec<usize>,
}

fn build_line_index(content: &[u8]) -> LineIndex {
    let mut starts = Vec::new();
    starts.push(0);
    for i in 0..content.len() {
        if content[i] == b'\n' && i + 1 <= content.len() {
            starts.push(i + 1);
        }
    }
    LineIndex { starts }
}

fn line_number_at(index: &LineIndex, pos: usize) -> usize {
    match index.starts.binary_search(&pos) {
        Ok(i) => i + 1,
        Err(i) => i,
    }
}

/// Test macro types we recognize
const MACROS: &[&str] = &[
    "TEST_FUNCTION",
    "TEST_METHOD",
    "CTEST_FUNCTION",
    "PARAMETERIZED_TEST_FUNCTION",
];

/// Keywords/macros to exclude from helper function detection
const EXCLUDED_NAMES: &[&str] = &[
    "TEST_FUNCTION",
    "TEST_METHOD",
    "CTEST_FUNCTION",
    "PARAMETERIZED_TEST_FUNCTION",
    "if",
    "while",
    "for",
    "switch",
    "else",
    "do",
    "TEST_DEFINE_ENUM_TYPE",
    "TEST_SUITE_INITIALIZE",
    "TEST_SUITE_CLEANUP",
    "TEST_FUNCTION_INITIALIZE",
    "TEST_FUNCTION_CLEANUP",
];

struct TestFuncMatch {
    macro_name: String,
    test_name: String,
    match_pos: usize,
    match_end: usize,
}

/// Find all test macro invocations in content.
/// Matches: optional leading whitespace, MACRO_NAME(identifier)
fn find_test_functions(content: &[u8]) -> Vec<TestFuncMatch> {
    let len = content.len();
    let mut results = Vec::new();
    let mut pos = 0usize;

    while pos < len {
        // Save position at start of potential match (before whitespace skip)
        let match_start = pos;

        // Skip leading whitespace
        while pos < len && (content[pos] == b' ' || content[pos] == b'\t') {
            pos += 1;
        }

        if pos >= len {
            break;
        }

        // Try to match each macro
        let mut matched = false;
        for macro_name in MACROS {
            let macro_bytes = macro_name.as_bytes();
            let mlen = macro_bytes.len();
            if pos + mlen <= len && &content[pos..pos + mlen] == macro_bytes {
                // After macro name, skip optional whitespace then expect '('
                let mut p = pos + mlen;
                while p < len && (content[p] == b' ' || content[p] == b'\t') {
                    p += 1;
                }
                if p < len && content[p] == b'(' {
                    p += 1;
                    // Skip whitespace
                    while p < len && (content[p] == b' ' || content[p] == b'\t') {
                        p += 1;
                    }
                    // Extract identifier
                    let name_start = p;
                    while p < len && is_ident_char(content[p]) {
                        p += 1;
                    }
                    if p > name_start {
                        let test_name =
                            String::from_utf8_lossy(&content[name_start..p]).to_string();
                        // Skip to closing paren (might have comma for PARAMETERIZED)
                        while p < len && content[p] != b')' {
                            p += 1;
                        }
                        if p < len {
                            p += 1; // skip ')'
                        }
                        results.push(TestFuncMatch {
                            macro_name: macro_name.to_string(),
                            test_name,
                            match_pos: match_start,
                            match_end: p,
                        });
                        matched = true;
                        // Skip to end of line
                        while p < len && content[p] != b'\n' {
                            p += 1;
                        }
                        if p < len {
                            p += 1;
                        }
                        pos = p;
                        break;
                    }
                }
            }
        }

        if !matched {
            // Skip to next line
            while pos < len && content[pos] != b'\n' {
                pos += 1;
            }
            if pos < len {
                pos += 1;
            }
        }
    }

    results
}

fn is_ident_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Extract function body starting from start_index.
/// Finds the opening '{' then counts braces, skipping string/char literals.
/// Returns the body content between { and } (inclusive).
fn extract_function_body(content: &[u8], start_index: usize) -> Option<(usize, Vec<u8>)> {
    let len = content.len();

    // Find opening brace
    let mut brace_start = start_index;
    while brace_start < len && content[brace_start] != b'{' {
        brace_start += 1;
    }
    if brace_start >= len {
        return None;
    }

    let mut brace_count = 1i32;
    let mut pos = brace_start + 1;

    while brace_count > 0 && pos < len {
        let ch = content[pos];

        // Skip string literals
        if ch == b'"' {
            pos += 1;
            while pos < len {
                if content[pos] == b'\\' && pos + 1 < len {
                    pos += 2;
                } else if content[pos] == b'"' {
                    pos += 1;
                    break;
                } else {
                    pos += 1;
                }
            }
            continue;
        }

        // Skip character literals
        if ch == b'\'' {
            pos += 1;
            while pos < len {
                if content[pos] == b'\\' && pos + 1 < len {
                    pos += 2;
                } else if content[pos] == b'\'' {
                    pos += 1;
                    break;
                } else {
                    pos += 1;
                }
            }
            continue;
        }

        if ch == b'{' {
            brace_count += 1;
        } else if ch == b'}' {
            brace_count -= 1;
        }
        pos += 1;
    }

    if brace_count == 0 {
        Some((brace_start, content[brace_start..pos].to_vec()))
    } else {
        None
    }
}

/// AAA marker positions: (arrange_pos, act_pos, assert_pos), -1 if not found
fn find_aaa_positions(body: &[u8]) -> [i64; 3] {
    let mut positions = [-1i64; 3];

    let keywords: [(&[u8], usize); 3] = [
        (b"arrange", 0),
        (b"act", 1),
        (b"assert", 2),
    ];

    let len = body.len();

    for (keyword, idx) in &keywords {
        let klen = keyword.len();
        let mut p = 0usize;

        while p + klen <= len {
            // Look for "//" or "/*"
            if p + 1 < len && body[p] == b'/' && (body[p + 1] == b'/' || body[p + 1] == b'*') {
                let is_block = body[p + 1] == b'*';
                let comment_start = p;
                let mut q = p + 2;

                // For line comments, skip additional '/' chars (e.g. "///")
                if !is_block {
                    while q < len && body[q] == b'/' {
                        q += 1;
                    }
                }

                // Skip whitespace
                while q < len && (body[q] == b' ' || body[q] == b'\t') {
                    q += 1;
                }

                // Check keyword (case-insensitive)
                if q + klen <= len && eq_ignore_case(&body[q..q + klen], keyword) {
                    // Word boundary check: char after keyword should not be alphanumeric or _
                    let after = q + klen;
                    if after >= len || !is_ident_char(body[after]) {
                        if positions[*idx] < 0 {
                            positions[*idx] = comment_start as i64;
                        }
                    }
                }

                // Skip rest of line/comment
                if is_block {
                    while q < len {
                        if q + 1 < len && body[q] == b'*' && body[q + 1] == b'/' {
                            q += 2;
                            break;
                        }
                        q += 1;
                    }
                    p = q;
                } else {
                    while q < len && body[q] != b'\n' {
                        q += 1;
                    }
                    p = q;
                }
            } else {
                p += 1;
            }
        }
    }

    positions
}

fn eq_ignore_case(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    for i in 0..a.len() {
        if a[i].to_ascii_lowercase() != b[i].to_ascii_lowercase() {
            return false;
        }
    }
    true
}

/// Get the full line containing a position (for checking no-aaa exemptions)
fn get_line_at(content: &[u8], match_end: usize) -> &[u8] {
    let len = content.len();
    // Find start of line containing match_end
    let mut line_start = if match_end > 0 { match_end - 1 } else { 0 };
    while line_start > 0 && content[line_start] != b'\n' {
        line_start -= 1;
    }
    if content[line_start] == b'\n' {
        line_start += 1;
    }
    // Skip \r
    while line_start < len && content[line_start] == b'\r' {
        line_start += 1;
    }
    // Find end of line
    let mut line_end = match_end;
    while line_end < len && content[line_end] != b'\n' {
        line_end += 1;
    }
    &content[line_start..line_end]
}

/// Check if a line contains "no-aaa" in a comment
fn has_no_aaa_exemption(line: &[u8]) -> bool {
    let len = line.len();
    if len < 6 {
        return false;
    }

    // Search for "no-aaa" (case-insensitive)
    for i in 0..len.saturating_sub(5) {
        if eq_ignore_case(&line[i..i + 6], b"no-aaa") {
            // Verify it's in a comment: scan backwards for // or /*
            if i >= 2 {
                let mut j = i;
                while j > 0 {
                    j -= 1;
                    if j > 0 && line[j] == b'/' && line[j - 1] == b'/' {
                        return true;
                    }
                    if line[j] == b'*' && j > 0 && line[j - 1] == b'/' {
                        return true;
                    }
                    if line[j] != b' ' && line[j] != b'\t' && line[j] != b'*' && line[j] != b'/' {
                        break;
                    }
                }
            }
        }
    }
    false
}

/// C return type keywords used to identify helper function definitions
const RETURN_TYPES: &[&[u8]] = &[
    b"void", b"int", b"bool", b"char", b"unsigned", b"signed", b"long",
    b"short", b"float", b"double", b"size_t",
];

fn is_return_type_prefix(word: &[u8]) -> bool {
    for rt in RETURN_TYPES {
        if word == *rt {
            return true;
        }
    }
    // uint*_t, int*_t patterns
    if word.len() >= 5 && word[word.len() - 2] == b'_' && word[word.len() - 1] == b't' {
        let prefix = &word[..word.len() - 2];
        if prefix.starts_with(b"uint") || prefix.starts_with(b"int") {
            return prefix[if prefix.starts_with(b"uint") { 4 } else { 3 }..]
                .iter()
                .all(|b| b.is_ascii_digit());
        }
    }
    // THANDLE(...)
    if word.len() >= 8 && word.starts_with(b"THANDLE") {
        return true;
    }
    false
}

struct HelperFunc {
    brace_pos: usize,
}

/// Find helper function definitions in the file content.
/// Returns map of function_name -> brace position for body extraction.
fn find_helper_functions(content: &[u8]) -> HashMap<String, HelperFunc> {
    let mut helpers = HashMap::new();
    let len = content.len();
    let mut pos = 0usize;

    while pos < len {
        // Must be at start of line
        let _line_start = pos;

        // Skip whitespace (for possible "static" keyword)
        while pos < len && (content[pos] == b' ' || content[pos] == b'\t') {
            pos += 1;
        }

        if pos >= len {
            break;
        }

        // Check for "static " prefix
        let mut p = pos;
        if p + 7 <= len && &content[p..p + 6] == b"static" && (content[p + 6] == b' ' || content[p + 6] == b'\t') {
            p += 6;
            while p < len && (content[p] == b' ' || content[p] == b'\t') {
                p += 1;
            }
        }

        // Check for return type
        // Handle THANDLE(...) specially
        if p + 7 <= len && &content[p..p + 7] == b"THANDLE" {
            // Skip THANDLE(...)
            while p < len && content[p] != b'(' {
                p += 1;
            }
            if p < len {
                let mut paren_depth = 1;
                p += 1;
                while p < len && paren_depth > 0 {
                    if content[p] == b'(' { paren_depth += 1; }
                    if content[p] == b')' { paren_depth -= 1; }
                    p += 1;
                }
            }
        } else {
            // Read type word
            let word_start = p;
            while p < len && is_ident_char(content[p]) {
                p += 1;
            }
            if p == word_start || !is_return_type_prefix(&content[word_start..p]) {
                // Not a recognized return type, skip line
                while pos < len && content[pos] != b'\n' {
                    pos += 1;
                }
                if pos < len { pos += 1; }
                continue;
            }
        }

        // Skip whitespace and optional pointer '*'
        while p < len && (content[p] == b' ' || content[p] == b'\t') {
            p += 1;
        }
        if p < len && content[p] == b'*' {
            p += 1;
        }
        while p < len && (content[p] == b' ' || content[p] == b'\t') {
            p += 1;
        }

        // Read function name
        let name_start = p;
        while p < len && is_ident_char(content[p]) {
            p += 1;
        }

        if p > name_start {
            let func_name = String::from_utf8_lossy(&content[name_start..p]).to_string();

            // Check it's not an excluded name
            let excluded = EXCLUDED_NAMES.iter().any(|e| *e == func_name.as_str());

            if !excluded {
                // Skip whitespace, expect '('
                while p < len && (content[p] == b' ' || content[p] == b'\t') {
                    p += 1;
                }

                if p < len && content[p] == b'(' {
                    // Find matching closing paren
                    let mut paren_count = 1;
                    p += 1;
                    while p < len && paren_count > 0 {
                        if content[p] == b'(' { paren_count += 1; }
                        if content[p] == b')' { paren_count -= 1; }
                        p += 1;
                    }

                    if paren_count == 0 {
                        // Skip whitespace, look for '{'
                        while p < len && (content[p] == b' ' || content[p] == b'\t' || content[p] == b'\r' || content[p] == b'\n') {
                            p += 1;
                        }

                        if p < len && content[p] == b'{' {
                            helpers.insert(func_name, HelperFunc { brace_pos: p });
                        }
                    }
                }
            }
        }

        // Skip to next line from original position
        while pos < len && content[pos] != b'\n' {
            pos += 1;
        }
        if pos < len {
            pos += 1;
        }
    }

    helpers
}

/// Find all function calls in a body: identifier followed by '('
fn find_called_functions(body: &[u8]) -> Vec<String> {
    let mut calls = Vec::new();
    let len = body.len();
    let mut p = 0usize;

    while p < len {
        // Find start of an identifier
        if is_ident_char(body[p]) && (p == 0 || !is_ident_char(body[p - 1])) {
            let name_start = p;
            while p < len && is_ident_char(body[p]) {
                p += 1;
            }
            let name = &body[name_start..p];
            // Skip whitespace
            while p < len && (body[p] == b' ' || body[p] == b'\t') {
                p += 1;
            }
            if p < len && body[p] == b'(' {
                if let Ok(s) = std::str::from_utf8(name) {
                    calls.push(s.to_string());
                }
            }
        } else {
            p += 1;
        }
    }

    calls
}

impl Check for AaaComments {
    fn name(&self) -> &str {
        "aaa_comments"
    }

    fn description(&self) -> &str {
        "Validates test functions contain AAA (Arrange, Act, Assert) comments"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_C
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
        self.total_test_functions = 0;
        self.exempted_tests = 0;
    }

    fn check_file(&mut self, file: &FileInfo, _config: &ValidatorConfig) {
        if file.type_flags & FILE_TYPE_C == 0 {
            return;
        }

        // Only check *_ut.c files (not integration tests)
        let filename = extract_filename(&file.path);
        if !filename.ends_with("_ut.c") {
            return;
        }

        let content = &file.content;
        if content.is_empty() {
            return;
        }

        let line_index = build_line_index(content);
        let test_funcs = find_test_functions(content);
        if test_funcs.is_empty() {
            return;
        }

        // Lazy-init helper functions
        let mut helpers: Option<HashMap<String, HelperFunc>> = None;
        let mut helper_aaa_cache: HashMap<String, [i64; 3]> = HashMap::new();

        for tf in &test_funcs {
            self.total_test_functions += 1;

            // Check for no-aaa exemption on the test macro line
            let test_line = get_line_at(content, tf.match_end);
            if has_no_aaa_exemption(test_line) {
                self.exempted_tests += 1;
                continue;
            }

            // Extract function body
            let body = match extract_function_body(content, tf.match_pos) {
                Some((_, b)) => b,
                None => continue,
            };

            // Check AAA in body
            let mut positions = find_aaa_positions(&body);
            let all_found = positions[0] >= 0 && positions[1] >= 0 && positions[2] >= 0;

            if all_found {
                // Check order
                if positions[0] < positions[1] && positions[1] < positions[2] {
                    continue; // Valid
                }
                // Wrong order
                let line_num = line_number_at(&line_index, tf.match_pos);
                println!(
                    "  [ERROR] {}:{} {}({}) - AAA comments are not in correct order (should be: arrange, act, assert)",
                    file.relative_path, line_num, tf.macro_name, tf.test_name
                );
                self.violations += 1;
                continue;
            }

            // Not all found - check helper functions
            if helpers.is_none() {
                helpers = Some(find_helper_functions(content));
            }
            let helper_map = helpers.as_ref().unwrap();

            let called_fns = find_called_functions(&body);
            for called in &called_fns {
                if let Some(helper) = helper_map.get(called) {
                    let h_positions = helper_aaa_cache.entry(called.clone()).or_insert_with(|| {
                        match extract_function_body(content, helper.brace_pos) {
                            Some((_, hbody)) => find_aaa_positions(&hbody),
                            None => [-1, -1, -1],
                        }
                    });
                    if h_positions[0] >= 0 { positions[0] = 0; }
                    if h_positions[1] >= 0 { positions[1] = 0; }
                    if h_positions[2] >= 0 { positions[2] = 0; }
                }
                if positions[0] >= 0 && positions[1] >= 0 && positions[2] >= 0 {
                    break;
                }
            }

            // Report missing
            let mut missing = Vec::new();
            if positions[0] < 0 { missing.push("arrange"); }
            if positions[1] < 0 { missing.push("act"); }
            if positions[2] < 0 { missing.push("assert"); }

            if !missing.is_empty() {
                let line_num = line_number_at(&line_index, tf.match_pos);
                println!(
                    "  [ERROR] {}:{} {}({}) - missing AAA: {}",
                    file.relative_path, line_num, tf.macro_name, tf.test_name,
                    missing.join(", ")
                );
                self.violations += 1;
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        println!();
        println!(
            "  Test functions: {}, exempted: {}, violations: {}",
            self.total_test_functions, self.exempted_tests, self.violations
        );
        self.violations
    }
}

fn extract_filename(path: &str) -> &str {
    if let Some(pos) = path.rfind(std::path::MAIN_SEPARATOR) {
        &path[pos + 1..]
    } else if let Some(pos) = path.rfind('/') {
        &path[pos + 1..]
    } else {
        path
    }
}
