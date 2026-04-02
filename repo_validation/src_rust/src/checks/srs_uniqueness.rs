// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::collections::HashMap;
use std::path::MAIN_SEPARATOR;

struct SrsEntry {
    file_path: String,
    line_number: i32,
}

pub struct SrsUniqueness {
    tags: HashMap<String, SrsEntry>,
    total_tags: i32,
    duplicate_found: bool,
    files_scanned: i32,
}

impl SrsUniqueness {
    pub fn new() -> Self {
        Self {
            tags: HashMap::new(),
            total_tags: 0,
            duplicate_found: false,
            files_scanned: 0,
        }
    }
}

fn is_srs_module_char(c: u8) -> bool {
    (c >= b'A' && c <= b'Z') || (c >= b'0' && c <= b'9') || c == b'_'
}

fn compute_line_number(content: &[u8], offset: usize) -> i32 {
    let mut line = 1;
    for i in 0..offset {
        if content[i] == b'\n' {
            line += 1;
        }
    }
    line
}

fn extract_filename(path: &str) -> &str {
    if let Some(pos) = path.rfind(MAIN_SEPARATOR) {
        &path[pos + 1..]
    } else if let Some(pos) = path.rfind('/') {
        &path[pos + 1..]
    } else {
        path
    }
}

impl Check for SrsUniqueness {
    fn name(&self) -> &str {
        "srs_uniqueness"
    }

    fn description(&self) -> &str {
        "Validates that SRS tags are unique across requirement documents"
    }

    fn file_types(&self) -> u32 {
        FILE_TYPE_MD
    }

    fn requires_devdoc(&self) -> bool {
        true
    }

    fn init(&mut self, _config: &ValidatorConfig) {
        self.tags.clear();
        self.total_tags = 0;
        self.duplicate_found = false;
        self.files_scanned = 0;
    }

    fn check_file(&mut self, file: &FileInfo, _config: &ValidatorConfig) {
        if file.type_flags & FILE_TYPE_MD == 0 {
            return;
        }
        if file.type_flags & FILE_FLAG_IN_DEVDOC == 0 {
            return;
        }

        self.files_scanned += 1;

        let content = &file.content;
        let len = content.len();
        let mut p = 0usize;

        while p + 6 < len {
            // Find '*'
            let star = match content[p..].iter().position(|&b| b == b'*') {
                Some(pos) => p + pos,
                None => break,
            };

            if star + 6 >= len {
                break;
            }

            if content[star + 1] == b'*'
                && content[star + 2] == b'S'
                && content[star + 3] == b'R'
                && content[star + 4] == b'S'
                && content[star + 5] == b'_'
            {
                let tag_start = star + 2; // 'S' of SRS
                let mut colon = star + 6; // after "**SRS_"

                // Scan forward for ':' (end of tag)
                while colon < len
                    && content[colon] != b':'
                    && content[colon] != b'\n'
                    && content[colon] != b'\r'
                {
                    if !is_srs_module_char(content[colon]) {
                        break;
                    }
                    colon += 1;
                }

                if colon >= len || content[colon] != b':' {
                    p = star + 2;
                    continue;
                }

                // Validate tag ends with _DD_DDD
                let tag_len = colon - tag_start;
                if tag_len < 11 {
                    p = star + 2;
                    continue;
                }

                let c = content; // alias
                if !c[colon - 1].is_ascii_digit()
                    || !c[colon - 2].is_ascii_digit()
                    || !c[colon - 3].is_ascii_digit()
                    || c[colon - 4] != b'_'
                    || !c[colon - 5].is_ascii_digit()
                    || !c[colon - 6].is_ascii_digit()
                    || c[colon - 7] != b'_'
                {
                    p = star + 2;
                    continue;
                }

                if colon - 7 <= star + 6 {
                    p = star + 2;
                    continue;
                }

                if tag_len >= 256 {
                    p = star + 2;
                    continue;
                }

                let tag = match std::str::from_utf8(&content[tag_start..colon]) {
                    Ok(s) => s.to_string(),
                    Err(_) => {
                        p = star + 2;
                        continue;
                    }
                };

                let line = compute_line_number(content, star);
                self.total_tags += 1;

                if let Some(existing) = self.tags.get(&tag) {
                    self.duplicate_found = true;

                    let fname1 = extract_filename(&existing.file_path);
                    let fname2 = extract_filename(&file.path);

                    println!("  [ERROR] Duplicate SRS tag: {}", tag);
                    println!(
                        "          First occurrence: {}:{}",
                        fname1, existing.line_number
                    );
                    println!("          Duplicate found in: {}:{}", fname2, line);
                } else {
                    self.tags.insert(
                        tag,
                        SrsEntry {
                            file_path: file.path.clone(),
                            line_number: line,
                        },
                    );
                }

                p = colon + 1;
            } else {
                p = star + 1;
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        println!();
        println!(
            "  Requirement documents scanned: {}",
            self.files_scanned
        );
        println!("  Total SRS tags found: {}", self.total_tags);

        if self.duplicate_found {
            1
        } else {
            0
        }
    }
}
