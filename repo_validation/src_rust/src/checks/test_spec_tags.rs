// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;

pub struct TestSpecTags {
    violations: i32,
    total_test_functions: i32,
    tests_with_tags: i32,
    exempted_tests: i32,
}

impl TestSpecTags {
    pub fn new() -> Self {
        Self {
            violations: 0,
            total_test_functions: 0,
            tests_with_tags: 0,
            exempted_tests: 0,
        }
    }
}

struct LineIndex {
    starts: Vec<usize>,
    lengths: Vec<usize>,
}

fn build_line_index(content: &[u8]) -> LineIndex {
    let len = content.len();
    let mut starts = Vec::new();
    let mut lengths = Vec::new();
    let mut line_start = 0usize;

    for i in 0..=len {
        if i == len || content[i] == b'\n' {
            let mut line_len = i - line_start;
            if line_len > 0 && content[line_start + line_len - 1] == b'\r' {
                line_len -= 1;
            }
            starts.push(line_start);
            lengths.push(line_len);
            line_start = i + 1;
        }
    }

    LineIndex { starts, lengths }
}

fn get_line<'a>(content: &'a [u8], index: &LineIndex, i: usize) -> &'a [u8] {
    &content[index.starts[i]..index.starts[i] + index.lengths[i]]
}

/// Check if line starts with TEST_FUNCTION( or PARAMETERIZED_TEST_FUNCTION(
/// Returns: 0 = not a test function, 1 = TEST_FUNCTION, 2 = PARAMETERIZED_TEST_FUNCTION
fn is_test_function_line(line: &[u8]) -> u8 {
    let len = line.len();
    let mut p = 0;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }

    if len - p >= 28
        && &line[p..p + 27] == b"PARAMETERIZED_TEST_FUNCTION"
        && (line[p + 27] == b'(' || line[p + 27] == b' ' || line[p + 27] == b'\t')
    {
        2
    } else if len - p >= 14
        && &line[p..p + 13] == b"TEST_FUNCTION"
        && (line[p + 13] == b'(' || line[p + 13] == b' ' || line[p + 13] == b'\t')
    {
        1
    } else {
        0
    }
}

/// Extract test function name from TEST_FUNCTION(name) or PARAMETERIZED_TEST_FUNCTION(name, ...) line
/// For PARAMETERIZED_TEST_FUNCTION, extract up to the first comma (not closing paren)
fn extract_test_name(line: &[u8], macro_type: u8) -> String {
    let open = match line.iter().position(|&b| b == b'(') {
        Some(p) => p + 1,
        None => return String::new(),
    };

    let end_delim = if macro_type == 2 {
        // PARAMETERIZED_TEST_FUNCTION: name ends at first comma
        line[open..]
            .iter()
            .position(|&b| b == b',')
            .map(|p| open + p)
            .or_else(|| line[open..].iter().position(|&b| b == b')').map(|p| open + p))
    } else {
        line[open..].iter().position(|&b| b == b')').map(|p| open + p)
    };

    let close = match end_delim {
        Some(p) => p,
        None => return String::new(),
    };

    let mut start = open;
    let mut end = close;
    while start < end && (line[start] == b' ' || line[start] == b'\t') {
        start += 1;
    }
    while end > start && (line[end - 1] == b' ' || line[end - 1] == b'\t') {
        end -= 1;
    }

    String::from_utf8_lossy(&line[start..end]).to_string()
}

/// Check if line contains "// no-srs" or "/* no-srs */" (case-insensitive)
fn has_no_srs_exemption(line: &[u8]) -> bool {
    let len = line.len();
    if len < 6 {
        return false;
    }

    for i in 0..len.saturating_sub(5) {
        let ci = |idx: usize, lower: u8, upper: u8| line[idx] == lower || line[idx] == upper;
        if ci(i, b'n', b'N')
            && ci(i + 1, b'o', b'O')
            && line[i + 2] == b'-'
            && ci(i + 3, b's', b'S')
            && ci(i + 4, b'r', b'R')
            && ci(i + 5, b's', b'S')
        {
            // Scan backwards to find "//" or "/*"
            if i >= 2 {
                let mut j = i;
                let mut found_comment = false;

                while j > 0 && !found_comment {
                    j -= 1;
                    if j > 0 && line[j] == b'/' && line[j - 1] == b'/' {
                        found_comment = true;
                    } else if line[j] == b'*' && j > 0 && line[j - 1] == b'/' {
                        found_comment = true;
                    } else if line[j] != b' ' && line[j] != b'\t' && line[j] != b'*' && line[j] != b'/' {
                        break;
                    }
                }

                if found_comment {
                    return true;
                }
            }
        }
    }
    false
}

/// Check if line contains a Tests_ spec tag: Tests_<something>_DD_DDD
fn has_tests_spec_tag(line: &[u8]) -> bool {
    let len = line.len();
    if len < 7 {
        return false;
    }

    for i in 0..len.saturating_sub(6) {
        if line[i] == b'T'
            && line[i + 1] == b'e'
            && line[i + 2] == b's'
            && line[i + 3] == b't'
            && line[i + 4] == b's'
            && line[i + 5] == b'_'
        {
            let mut p = i + 6;
            while p < len
                && ((line[p] >= b'A' && line[p] <= b'Z')
                    || (line[p] >= b'0' && line[p] <= b'9')
                    || line[p] == b'_')
            {
                p += 1;
            }

            // Check backwards for _DD_DDD pattern
            if p - (i + 6) >= 7 {
                let tag_end = p;
                if tag_end >= i + 13
                    && line[tag_end - 1].is_ascii_digit()
                    && line[tag_end - 2].is_ascii_digit()
                    && line[tag_end - 3].is_ascii_digit()
                    && line[tag_end - 4] == b'_'
                    && line[tag_end - 5].is_ascii_digit()
                    && line[tag_end - 6].is_ascii_digit()
                    && line[tag_end - 7] == b'_'
                {
                    return true;
                }
            }
        }
    }
    false
}

fn is_blank_line(line: &[u8]) -> bool {
    line.iter().all(|&b| b == b' ' || b == b'\t')
}

/// Check if line looks like it's part of a comment
fn is_comment_line(line: &[u8]) -> bool {
    let len = line.len();
    let mut p = 0;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if p >= len {
        return true; // blank = continue searching
    }
    if p + 1 < len && line[p] == b'/' && line[p + 1] == b'*' {
        return true;
    }
    if line[p] == b'*' {
        return true;
    }
    if p + 1 < len && line[p] == b'/' && line[p + 1] == b'/' {
        return true;
    }

    // Check if line ends with */
    let mut q = len;
    while q > p && (line[q - 1] == b' ' || line[q - 1] == b'\t') {
        q -= 1;
    }
    if q - p >= 2 && line[q - 2] == b'*' && line[q - 1] == b'/' {
        return true;
    }

    false
}

impl Check for TestSpecTags {
    fn name(&self) -> &str {
        "test_spec_tags"
    }

    fn description(&self) -> &str {
        "Validates TEST_FUNCTION declarations have preceding spec tags"
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
        self.tests_with_tags = 0;
        self.exempted_tests = 0;
    }

    fn check_file(&mut self, file: &FileInfo, _config: &ValidatorConfig) {
        if file.type_flags & FILE_TYPE_C == 0 {
            return;
        }

        // Check filename ends with _ut.c
        let filename = if let Some(pos) = file.path.rfind(std::path::MAIN_SEPARATOR) {
            &file.path[pos + 1..]
        } else if let Some(pos) = file.path.rfind('/') {
            &file.path[pos + 1..]
        } else {
            &file.path
        };

        if filename.len() < 5 || !filename.ends_with("_ut.c") {
            return;
        }

        let index = build_line_index(&file.content);
        let line_count = index.starts.len();

        for i in 0..line_count {
            let line = get_line(&file.content, &index, i);

            let macro_type = is_test_function_line(line);

            if macro_type != 0 {
                self.total_test_functions += 1;

                if has_no_srs_exemption(line) {
                    self.exempted_tests += 1;
                    self.tests_with_tags += 1;
                } else {
                    // Search backwards for Tests_ spec tag
                    let mut found_tag = false;
                    let mut search_idx = i as i32 - 1;
                    let mut in_multiline_comment = false;

                    while search_idx >= 0 {
                        let prev = get_line(&file.content, &index, search_idx as usize);

                        if has_tests_spec_tag(prev) {
                            found_tag = true;
                        }

                        if is_blank_line(prev) {
                            search_idx -= 1;
                        } else {
                            // Track multi-line comment state (searching backwards)
                            let mut has_start = false;
                            let mut has_end = false;
                            let prev_len = prev.len();
                            for k in 0..prev_len.saturating_sub(1) {
                                if prev[k] == b'/' && prev[k + 1] == b'*' {
                                    has_start = true;
                                }
                                if prev[k] == b'*' && prev[k + 1] == b'/' {
                                    has_end = true;
                                }
                            }

                            if has_start && has_end {
                                // Single-line block comment
                            } else if has_start {
                                in_multiline_comment = false;
                            } else if has_end {
                                in_multiline_comment = true;
                            }

                            if in_multiline_comment {
                                search_idx -= 1;
                            } else if is_comment_line(prev) {
                                search_idx -= 1;
                            } else {
                                break;
                            }
                        }
                    }

                    if found_tag {
                        self.tests_with_tags += 1;
                    } else {
                        let macro_name = if macro_type == 2 { "PARAMETERIZED_TEST_FUNCTION" } else { "TEST_FUNCTION" };
                        let test_name = extract_test_name(line, macro_type);
                        println!(
                            "  [ERROR] {}:{} {}({}) - missing spec tag",
                            file.relative_path,
                            i + 1,
                            macro_name,
                            test_name
                        );
                        self.violations += 1;
                    }
                }
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        println!();
        println!(
            "  Unit test files: TEST_FUNCTION declarations: {}, with tags: {}, exempted: {}, missing: {}",
            self.total_test_functions, self.tests_with_tags, self.exempted_tests, self.violations
        );
        self.violations
    }
}
