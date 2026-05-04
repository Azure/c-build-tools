// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::fs;

pub struct NoTabs {
    violations: i32,
}

impl NoTabs {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

impl Check for NoTabs {
    fn name(&self) -> &str {
        "no_tabs"
    }

    fn description(&self) -> &str {
        "Validates that source files do not contain tab characters"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_CS | FILE_TYPE_MD
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
    }

    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig) {
        let content = &file.content;
        let mut tab_count = 0i32;
        let mut first_tab_line: i32 = -1;
        let mut current_line = 1i32;

        for &b in content.iter() {
            if b == b'\t' {
                tab_count += 1;
                if first_tab_line < 0 {
                    first_tab_line = current_line;
                }
            }
            if b == b'\n' {
                current_line += 1;
            }
        }

        if tab_count > 0 {
            if config.fix_mode {
                let mut new_content = Vec::with_capacity(content.len() + (tab_count as usize) * 3);
                for &b in content.iter() {
                    if b == b'\t' {
                        new_content.extend_from_slice(b"    ");
                    } else {
                        new_content.push(b);
                    }
                }
                if fs::write(&file.path, &new_content).is_ok() {
                    println!(
                        "  [FIXED] {} - replaced {} tab(s) with spaces",
                        file.relative_path, tab_count
                    );
                }
            } else {
                println!(
                    "  [ERROR] {} - contains {} tab(s), first at line {}",
                    file.relative_path, tab_count, first_tab_line
                );
                self.violations += 1;
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
