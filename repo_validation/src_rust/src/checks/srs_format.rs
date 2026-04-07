// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;

pub struct SrsFormat {
    violations: i32,
}

impl SrsFormat {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

/// Check if a tag name has a valid SRS suffix pattern (_DD_DDD where D is a digit)
fn has_valid_srs_suffix(tag: &[u8]) -> bool {
    let len = tag.len();
    if len < 11 {
        return false;
    }
    // Last 7 chars should be _DD_DDD
    tag[len - 7] == b'_'
        && tag[len - 6].is_ascii_digit()
        && tag[len - 5].is_ascii_digit()
        && tag[len - 4] == b'_'
        && tag[len - 3].is_ascii_digit()
        && tag[len - 2].is_ascii_digit()
        && tag[len - 1].is_ascii_digit()
}

impl Check for SrsFormat {
    fn name(&self) -> &str {
        "srs_format"
    }

    fn description(&self) -> &str {
        "Validates SRS requirement tag formatting in markdown files"
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

    fn check_file(&mut self, file: &FileInfo, _config: &ValidatorConfig) {
        let content = match std::str::from_utf8(&file.content) {
            Ok(s) => s,
            Err(_) => return,
        };

        let lines: Vec<&str> = content.lines().collect();

        for (line_idx, line) in lines.iter().enumerate() {
            let line_num = line_idx + 1;

            // Trim leading whitespace
            let trimmed = line.trim_start();

            // Strip optional list markers: "* " or "- "
            let after_marker = if trimmed.starts_with("* ") || trimmed.starts_with("- ") {
                trimmed[2..].trim_start()
            } else {
                trimmed
            };

            // Check for **SRS_ prefix
            if !after_marker.starts_with("**SRS_") {
                continue;
            }

            // Extract tag name: starts after "**", scan uppercase/digits/underscores
            let tag_start = &after_marker[2..];
            let tag_end = tag_start
                .find(|c: char| !c.is_ascii_uppercase() && !c.is_ascii_digit() && c != '_')
                .unwrap_or(tag_start.len());

            let tag = &tag_start[..tag_end];

            // Validate the tag has proper SRS format with _DD_DDD suffix
            if !tag.starts_with("SRS_") || !has_valid_srs_suffix(tag.as_bytes()) {
                continue;
            }

            let has_bold_open = line.contains("[**");

            if !has_bold_open {
                println!(
                    "  [ERROR] {}:{} {} - missing bold opening bracket [**",
                    file.relative_path, line_num, tag
                );
                self.violations += 1;
                continue;
            }

            // Check for **]** closing on this line or subsequent lines
            let has_bold_close = if line.contains("**]**") {
                true
            } else {
                // Scan subsequent lines for **]** (multi-line tag)
                let max_scan = std::cmp::min(lines.len(), line_idx + 50);
                let mut found = false;
                for subsequent in &lines[line_idx + 1..max_scan] {
                    let st = subsequent.trim_start();
                    // Strip optional list markers before checking for new tag
                    let after_list = if st.starts_with("* ") || st.starts_with("- ") {
                        st[2..].trim_start()
                    } else {
                        st
                    };
                    // Stop if we hit another SRS tag definition
                    if after_list.starts_with("**SRS_") {
                        break;
                    }
                    if subsequent.contains("**]**") {
                        found = true;
                        break;
                    }
                }
                found
            };

            if !has_bold_close {
                if line.contains("]*/") {
                    println!(
                        "  [ERROR] {}:{} {} - C-comment-style closing ]*/ (should be **]**)",
                        file.relative_path, line_num, tag
                    );
                } else if line.contains("**]") {
                    println!(
                        "  [ERROR] {}:{} {} - missing trailing ** after **]",
                        file.relative_path, line_num, tag
                    );
                } else {
                    println!(
                        "  [ERROR] {}:{} {} - missing closing **]**",
                        file.relative_path, line_num, tag
                    );
                }
                self.violations += 1;
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
