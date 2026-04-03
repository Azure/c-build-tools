// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::fs;

pub struct NoVldInclude {
    violations: i32,
}

impl NoVldInclude {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

/// Check if line matches #include "vld.h" or #include <vld.h>
fn is_vld_include(line: &[u8]) -> bool {
    let len = line.len();
    let mut p = 0;

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
    if len - p < 7 || &line[p..p + 7] != b"include" {
        return false;
    }
    p += 7;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if p >= len {
        return false;
    }

    if line[p] == b'"' {
        p += 1;
        if len - p >= 5 && &line[p..p + 5] == b"vld.h" {
            p += 5;
            p < len && line[p] == b'"'
        } else {
            false
        }
    } else if line[p] == b'<' {
        p += 1;
        if len - p >= 5 && &line[p..p + 5] == b"vld.h" {
            p += 5;
            p < len && line[p] == b'>'
        } else {
            false
        }
    } else {
        false
    }
}

/// Check if line ends with "// force" (case-insensitive)
fn line_has_force_comment(line: &[u8]) -> bool {
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
    let ci = |c: u8, lower: u8, upper: u8| c == lower || c == upper;
    if !ci(line[end - 5], b'f', b'F')
        || !ci(line[end - 4], b'o', b'O')
        || !ci(line[end - 3], b'r', b'R')
        || !ci(line[end - 2], b'c', b'C')
        || !ci(line[end - 1], b'e', b'E')
    {
        return false;
    }
    let mut j = end - 5;
    while j > 0 && (line[j - 1] == b' ' || line[j - 1] == b'\t') {
        j -= 1;
    }
    j >= 2 && line[j - 1] == b'/' && line[j - 2] == b'/'
}

/// Check if line matches "#ifdef USE_VLD"
fn is_ifdef_use_vld(line: &[u8]) -> bool {
    let len = line.len();
    let mut p = 0;

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
    if len - p < 5 || &line[p..p + 5] != b"ifdef" {
        return false;
    }
    p += 5;
    if p >= len || (line[p] != b' ' && line[p] != b'\t') {
        return false;
    }
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if len - p < 7 || &line[p..p + 7] != b"USE_VLD" {
        return false;
    }
    p += 7;
    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    p >= len
}

/// Check if line matches "#endif" (with optional comment)
fn is_endif(line: &[u8]) -> bool {
    let len = line.len();
    let mut p = 0;

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
    if len - p < 5 || &line[p..p + 5] != b"endif" {
        return false;
    }
    true
}

/// Check if line is blank or a comment-only line
fn is_blank_or_comment(line: &[u8]) -> bool {
    let len = line.len();
    let mut p = 0;

    while p < len && (line[p] == b' ' || line[p] == b'\t') {
        p += 1;
    }
    if p >= len {
        return true; // blank
    }
    if p + 1 < len && line[p] == b'/' && line[p + 1] == b'/' {
        return true; // line comment
    }
    false
}

struct LineInfo {
    /// Line content without \r\n
    trimmed: Vec<u8>,
    /// Raw bytes including \r\n
    raw: Vec<u8>,
}

fn parse_lines(content: &[u8]) -> Vec<LineInfo> {
    let len = content.len();
    let mut lines = Vec::new();
    let mut line_start = 0usize;

    for i in 0..=len {
        if i == len || content[i] == b'\n' {
            let raw_end = if i < len { i + 1 } else { i };
            let raw = content[line_start..raw_end].to_vec();

            let mut trimmed_len = i - line_start;
            if trimmed_len > 0 && content[line_start + trimmed_len - 1] == b'\r' {
                trimmed_len -= 1;
            }
            let trimmed = content[line_start..line_start + trimmed_len].to_vec();

            lines.push(LineInfo { trimmed, raw });
            line_start = i + 1;
        }
    }
    lines
}

impl Check for NoVldInclude {
    fn name(&self) -> &str {
        "no_vld_include"
    }

    fn description(&self) -> &str {
        "Validates files do not explicitly include vld.h"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_TXT
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
    }

    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig) {
        let lines = parse_lines(&file.content);

        // Count violations
        let mut violation_count = 0i32;
        for line in &lines {
            if is_vld_include(&line.trimmed) && !line_has_force_comment(&line.trimmed) {
                violation_count += 1;
            }
        }

        if violation_count == 0 {
            return;
        }

        if config.fix_mode {
            let mut output = Vec::with_capacity(file.content.len());
            let mut removed = 0i32;
            let line_count = lines.len();
            let mut idx = 0;

            while idx < line_count {
                let mut was_removed = false;

                // Check if this is an #ifdef USE_VLD block
                if is_ifdef_use_vld(&lines[idx].trimmed) {
                    let mut j = idx + 1;
                    let mut found_vld = false;
                    let mut found_endif = false;
                    let mut only_vld = true;

                    while j < line_count {
                        if is_vld_include(&lines[j].trimmed) {
                            found_vld = true;
                            j += 1;
                        } else if is_endif(&lines[j].trimmed) {
                            found_endif = true;
                            break;
                        } else if is_blank_or_comment(&lines[j].trimmed) {
                            j += 1;
                        } else {
                            only_vld = false;
                            break;
                        }
                    }

                    if found_vld && found_endif && only_vld {
                        removed += 1;
                        idx = j + 1; // skip past #endif
                        was_removed = true;
                    }
                }

                if !was_removed {
                    if is_vld_include(&lines[idx].trimmed)
                        && !line_has_force_comment(&lines[idx].trimmed)
                    {
                        removed += 1;
                    } else {
                        output.extend_from_slice(&lines[idx].raw);
                    }
                    idx += 1;
                }
            }

            // Ensure file ends with CRLF
            if output.len() >= 2
                && !(output[output.len() - 2] == b'\r' && output[output.len() - 1] == b'\n')
            {
                if output[output.len() - 1] == b'\n' {
                    let last = output.len() - 1;
                    output[last] = b'\r';
                    output.push(b'\n');
                } else {
                    output.push(b'\r');
                    output.push(b'\n');
                }
            }

            if fs::write(&file.path, &output).is_ok() {
                println!(
                    "  [FIXED] {} - removed {} vld.h include(s)",
                    file.relative_path, removed
                );
            }
        } else {
            println!(
                "  [ERROR] {} - contains {} vld.h include(s)",
                file.relative_path, violation_count
            );
            self.violations += 1;
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
