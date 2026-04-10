// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use std::fs;

pub struct NoBackticksInSrs {
    violations: i32,
}

impl NoBackticksInSrs {
    pub fn new() -> Self {
        Self { violations: 0 }
    }
}

/// Find SRS tags with backticks in the bracketed text
/// Pattern: SRS_<MODULE>_DD_DDD : [ text with ` backticks ` ]
fn find_srs_backticks(content: &[u8]) -> i32 {
    let len = content.len();
    let mut count = 0i32;
    let mut p = 0usize;

    while p + 4 < len {
        // Find 'S'
        let srs = match content[p..].iter().position(|&b| b == b'S') {
            Some(pos) => p + pos,
            None => break,
        };

        if srs + 4 >= len {
            break;
        }

        if content[srs + 1] == b'R' && content[srs + 2] == b'S' && content[srs + 3] == b'_' {
            let mut q = srs + 4;
            // Scan module/tag chars
            while q < len
                && ((content[q] >= b'A' && content[q] <= b'Z')
                    || (content[q] >= b'0' && content[q] <= b'9')
                    || content[q] == b'_')
            {
                q += 1;
            }

            // Skip optional whitespace
            while q < len && (content[q] == b' ' || content[q] == b'\t') {
                q += 1;
            }

            // Check for colon
            if q < len && content[q] == b':' {
                q += 1;
                // Skip whitespace
                while q < len && (content[q] == b' ' || content[q] == b'\t') {
                    q += 1;
                }

                // Check for opening bracket
                if q < len && content[q] == b'[' {
                    q += 1;
                    let mut has_backtick = false;
                    while q < len && content[q] != b']' {
                        if content[q] == b'`' {
                            has_backtick = true;
                        }
                        q += 1;
                    }

                    if has_backtick && q < len && content[q] == b']' {
                        count += 1;
                    }
                }
            }
            p = if q < len { q } else { len };
        } else {
            p = srs + 1;
        }
    }

    count
}

/// Fix: remove backticks from SRS bracketed text
fn fix_srs_backticks(content: &[u8]) -> Vec<u8> {
    let len = content.len();
    let mut result = Vec::with_capacity(len);
    let mut p = 0usize;

    while p < len {
        if p + 4 <= len
            && content[p] == b'S'
            && content[p + 1] == b'R'
            && content[p + 2] == b'S'
            && content[p + 3] == b'_'
        {
            // Copy "SRS_"
            result.push(content[p]);
            result.push(content[p + 1]);
            result.push(content[p + 2]);
            result.push(content[p + 3]);
            p += 4;

            // Copy module/tag chars
            while p < len
                && ((content[p] >= b'A' && content[p] <= b'Z')
                    || (content[p] >= b'0' && content[p] <= b'9')
                    || content[p] == b'_')
            {
                result.push(content[p]);
                p += 1;
            }

            // Copy whitespace
            while p < len && (content[p] == b' ' || content[p] == b'\t') {
                result.push(content[p]);
                p += 1;
            }

            // Check for colon
            if p < len && content[p] == b':' {
                result.push(content[p]);
                p += 1;

                // Copy whitespace
                while p < len && (content[p] == b' ' || content[p] == b'\t') {
                    result.push(content[p]);
                    p += 1;
                }

                // Check for bracket
                if p < len && content[p] == b'[' {
                    result.push(content[p]);
                    p += 1;

                    // Inside bracket: copy everything except backticks until ]
                    while p < len && content[p] != b']' {
                        if content[p] != b'`' {
                            result.push(content[p]);
                        }
                        p += 1;
                    }

                    // Copy closing bracket if present
                    if p < len && content[p] == b']' {
                        result.push(content[p]);
                        p += 1;
                    }
                }
            }
        } else {
            result.push(content[p]);
            p += 1;
        }
    }

    result
}

impl Check for NoBackticksInSrs {
    fn name(&self) -> &str {
        "no_backticks_in_srs"
    }

    fn description(&self) -> &str {
        "Validates SRS comments do not contain markdown backticks"
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
        let match_count = find_srs_backticks(&file.content);

        if match_count > 0 {
            if config.fix_mode {
                let fixed = fix_srs_backticks(&file.content);
                if fs::write(&file.path, &fixed).is_ok() {
                    println!(
                        "  [FIXED] {} - removed backticks from {} SRS requirement(s)",
                        file.relative_path, match_count
                    );
                }
            } else {
                println!(
                    "  [ERROR] {} - {} SRS requirement(s) contain backticks",
                    file.relative_path, match_count
                );
                self.violations += 1;
            }
        }
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        self.violations
    }
}
