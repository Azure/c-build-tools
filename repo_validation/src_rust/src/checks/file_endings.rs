// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::fs;

pub struct FileEndings {
    violations: i32,
}

impl FileEndings {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

impl Check for FileEndings {
    fn name(&self) -> &str {
        "file_endings"
    }

    fn description(&self) -> &str {
        "Validates that source files end with a CRLF newline"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_CS
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
    }

    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig) {
        let content = &file.content;
        if content.is_empty() {
            return;
        }

        let last_byte = content[content.len() - 1];
        let second_last = if content.len() >= 2 {
            content[content.len() - 2]
        } else {
            0
        };

        if last_byte == b'\n' && second_last == b'\r' {
            // Proper CRLF ending
            return;
        }

        let issue = if last_byte == b'\n' {
            "ends with LF only (expected CRLF)"
        } else if last_byte == b'\r' {
            "ends with CR only (expected CRLF)"
        } else {
            "missing newline at end of file"
        };

        if config.fix_mode {
            if last_byte == b'\n' {
                // LF only - replace last byte with CRLF
                let mut new_content = Vec::with_capacity(content.len() + 1);
                new_content.extend_from_slice(&content[..content.len() - 1]);
                new_content.extend_from_slice(b"\r\n");
                if fs::write(&file.path, &new_content).is_ok() {
                    println!(
                        "  [FIXED] {} - converted LF to CRLF at end of file",
                        file.relative_path
                    );
                }
            } else if last_byte == b'\r' {
                // CR only - append LF
                let mut new_content = content.clone();
                new_content.push(b'\n');
                if fs::write(&file.path, &new_content).is_ok() {
                    println!(
                        "  [FIXED] {} - appended LF after CR at end of file",
                        file.relative_path
                    );
                }
            } else {
                // No newline - append CRLF
                let mut new_content = content.clone();
                new_content.extend_from_slice(b"\r\n");
                if fs::write(&file.path, &new_content).is_ok() {
                    println!(
                        "  [FIXED] {} - appended CRLF at end of file",
                        file.relative_path
                    );
                }
            }
        } else {
            println!("  [ERROR] {} - {}", file.relative_path, issue);
            self.violations += 1;
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
