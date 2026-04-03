// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::path::MAIN_SEPARATOR;

pub struct RequirementsNaming {
    violations: i32,
}

impl RequirementsNaming {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

/// Check if content contains an SRS tag pattern: SRS_XXXXXX_DD_DDD
fn content_has_srs_tag(content: &[u8]) -> bool {
    let len = content.len();
    if len < 16 {
        return false;
    }

    let mut i = 0;
    while i + 15 < len {
        if content[i] == b'S'
            && content[i + 1] == b'R'
            && content[i + 2] == b'S'
            && content[i + 3] == b'_'
        {
            let mut p = i + 4;
            let mut found_upper = false;

            while p < len.saturating_sub(6) {
                if content[p] >= b'A' && content[p] <= b'Z' {
                    found_upper = true;
                }
                if found_upper
                    && content[p] == b'_'
                    && content[p + 1].is_ascii_digit()
                    && content[p + 2].is_ascii_digit()
                    && content[p + 3] == b'_'
                    && content[p + 4].is_ascii_digit()
                    && content[p + 5].is_ascii_digit()
                    && content[p + 6].is_ascii_digit()
                {
                    return true;
                }
                if !((content[p] >= b'A' && content[p] <= b'Z')
                    || (content[p] >= b'0' && content[p] <= b'9')
                    || content[p] == b'_')
                {
                    break;
                }
                p += 1;
            }
        }
        i += 1;
    }
    false
}

impl Check for RequirementsNaming {
    fn name(&self) -> &str {
        "requirements_naming"
    }

    fn description(&self) -> &str {
        "Validates that requirement documents follow naming conventions"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_MD
    }

    fn requires_devdoc(&self) -> bool {
        true
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.violations = 0;
    }

    fn check_file(&mut self, file: &FileInfo, config: &ValidatorConfig) {
        if file.type_flags & FILE_TYPE_MD == 0 {
            return;
        }
        if file.type_flags & FILE_FLAG_IN_DEVDOC == 0 {
            return;
        }
        if !content_has_srs_tag(&file.content) {
            return;
        }

        // Extract filename
        let filename = if let Some(pos) = file.path.rfind(MAIN_SEPARATOR) {
            &file.path[pos + 1..]
        } else if let Some(pos) = file.path.rfind('/') {
            &file.path[pos + 1..]
        } else {
            &file.path
        };

        let suffix = "_requirements.md";
        if filename.len() >= suffix.len() && filename.ends_with(suffix) {
            return; // Already has correct naming
        }

        if config.fix_mode {
            // Rename: strip .md, append _requirements.md
            if file.path.len() < 3 {
                return;
            }
            let base = &file.path[..file.path.len() - 3];
            let new_path = format!("{}{}", base, "_requirements.md");
            if std::fs::rename(&file.path, &new_path).is_ok() {
                let new_filename = if let Some(pos) = new_path.rfind(MAIN_SEPARATOR) {
                    &new_path[pos + 1..]
                } else if let Some(pos) = new_path.rfind('/') {
                    &new_path[pos + 1..]
                } else {
                    &new_path
                };
                println!("  [FIXED] {} -> {}", file.relative_path, new_filename);
            } else {
                println!("  [ERROR] Failed to rename {}", file.relative_path);
                self.violations += 1;
            }
        } else {
            println!(
                "  [ERROR] {} - requirement file should be named with '_requirements.md' suffix",
                file.relative_path
            );
            self.violations += 1;
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
