// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::fs;

pub struct EnableMocks {
    violations: i32,
}

impl EnableMocks {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

/// Check if a line matches "#define ENABLE_MOCKS" (with optional leading whitespace)
fn is_define_enable_mocks(line: &[u8]) -> bool {
    let mut p = 0;
    let len = line.len();

    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if p >= len || line[p] != b'#' {
        return false;
    }
    p += 1;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if len - p < 6 || &line[p..p + 6] != b"define" {
        return false;
    }
    p += 6;
    if p >= len || (line[p] != b' ' && line[p] != b'\t') {
        return false;
    }
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if len - p < 12 || &line[p..p + 12] != b"ENABLE_MOCKS" {
        return false;
    }
    p += 12;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    p >= len
}

/// Check if a line matches "#undef ENABLE_MOCKS" (with optional leading whitespace)
fn is_undef_enable_mocks(line: &[u8]) -> bool {
    let mut p = 0;
    let len = line.len();

    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if p >= len || line[p] != b'#' {
        return false;
    }
    p += 1;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if len - p < 5 || &line[p..p + 5] != b"undef" {
        return false;
    }
    p += 5;
    if p >= len || (line[p] != b' ' && line[p] != b'\t') {
        return false;
    }
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if len - p < 12 || &line[p..p + 12] != b"ENABLE_MOCKS" {
        return false;
    }
    p += 12;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    p >= len
}

/// Check if line ends with "// force" (case-insensitive)
fn has_force_comment(line: &[u8]) -> bool {
    let len = line.len();
    if len < 8 {
        return false;
    }
    let mut end = len;
    while end > 0 && (line[end - 1] == b' ' || line[end - 1] == b'\t') {
        end -= 1;
    }
    if end < 8 {
        return false;
    }
    let check = |c: u8, lower: u8, upper: u8| c == lower || c == upper;
    if !check(line[end - 5], b'f', b'F')
        || !check(line[end - 4], b'o', b'O')
        || !check(line[end - 3], b'r', b'R')
        || !check(line[end - 2], b'c', b'C')
        || !check(line[end - 1], b'e', b'E')
    {
        return false;
    }
    let mut j = end - 5;
    while j > 0 && (line[j - 1] == b' ' || line[j - 1] == b'\t') {
        j -= 1;
    }
    j >= 2 && line[j - 1] == b'/' && line[j - 2] == b'/'
}

/// Split content into lines. Each line is the bytes without \r\n, but we track
/// the raw length including line terminators.
struct LineData {
    /// Content of line without \r or \n
    trimmed: Vec<u8>,
    /// The raw bytes including \r\n for non-replaced lines
    raw: Vec<u8>,
}

fn split_lines(content: &[u8]) -> Vec<LineData> {
    let len = content.len();
    let mut lines = Vec::new();
    let mut line_start = 0usize;

    for i in 0..=len {
        if i == len || content[i] == b'\n' {
            let raw_end = if i < len { i + 1 } else { i };
            let raw = &content[line_start..raw_end];

            let mut trimmed_len = i - line_start;
            if trimmed_len > 0 && content[line_start + trimmed_len - 1] == b'\r' {
                trimmed_len -= 1;
            }
            let trimmed = &content[line_start..line_start + trimmed_len];

            lines.push(LineData {
                trimmed: trimmed.to_vec(),
                raw: raw.to_vec(),
            });
            line_start = i + 1;
        }
    }
    lines
}

impl Check for EnableMocks {
    fn name(&self) -> &str {
        "enable_mocks"
    }

    fn description(&self) -> &str {
        "Validates files use include-based ENABLE_MOCKS pattern"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
    }

    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig) {
        let lines = split_lines(&file.content);
        let mut define_count = 0i32;
        let mut undef_count = 0i32;

        for line in &lines {
            let trimmed = &line.trimmed;
            if !trimmed.is_empty() && !has_force_comment(trimmed) {
                if is_define_enable_mocks(trimmed) {
                    define_count += 1;
                } else if is_undef_enable_mocks(trimmed) {
                    undef_count += 1;
                }
            }
        }

        let total_violations = define_count + undef_count;
        if total_violations == 0 {
            return;
        }

        if config.fix_mode {
            let mut output =
                Vec::with_capacity(file.content.len() + (total_violations as usize) * 128);

            for (idx, line) in lines.iter().enumerate() {
                let trimmed = &line.trimmed;
                let mut replaced = false;

                if !trimmed.is_empty() && !has_force_comment(trimmed) {
                    if is_define_enable_mocks(trimmed) {
                        let replacement = b"#include \"umock_c/umock_c_ENABLE_MOCKS.h\" // ============================== ENABLE_MOCKS";
                        output.extend_from_slice(replacement);
                        output.push(b'\r');
                        replaced = true;
                    } else if is_undef_enable_mocks(trimmed) {
                        let replacement = b"#include \"umock_c/umock_c_DISABLE_MOCKS.h\" // ============================== DISABLE_MOCKS";
                        output.extend_from_slice(replacement);
                        output.push(b'\r');
                        replaced = true;
                    }
                }

                if !replaced {
                    // Copy raw line bytes (without the trailing \n, we'll add it)
                    let raw = &line.raw;
                    if !raw.is_empty() && raw[raw.len() - 1] == b'\n' {
                        output.extend_from_slice(&raw[..raw.len() - 1]);
                    } else {
                        output.extend_from_slice(raw);
                    }
                }

                // Add newline if not the last line
                let is_last = idx == lines.len() - 1;
                let original_had_newline =
                    !line.raw.is_empty() && line.raw[line.raw.len() - 1] == b'\n';
                if !is_last || original_had_newline {
                    if is_last && !original_had_newline {
                        // don't add
                    } else {
                        output.push(b'\n');
                    }
                }
            }

            if fs::write(&file.path, &output).is_ok() {
                println!(
                    "  [FIXED] {} - replaced {} deprecated pattern(s)",
                    file.relative_path, total_violations
                );
            }
        } else {
            print!(
                "  [ERROR] {} - {} deprecated ENABLE_MOCKS pattern(s)",
                file.relative_path, total_violations
            );
            if define_count > 0 {
                print!(" (#define: {})", define_count);
            }
            if undef_count > 0 {
                print!(" (#undef: {})", undef_count);
            }
            println!();
            self.violations += 1;
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
