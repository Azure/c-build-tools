// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use crate::file_walker::is_path_excluded;
use std::fs;
use std::path::Path;
use std::process::Command;

pub struct CBuildToolsRef {
    violations: i32,
    fixed: i32,
}

impl CBuildToolsRef {
    pub fn new() -> Self {
        Self {
            violations: 0,
            fixed: 0,
        }
    }
}

/// Parse .gitmodules to find the submodule path whose url contains "c-build-tools".
/// Returns None if no match is found.
fn find_cbt_submodule_path(gitmodules_content: &str) -> Option<String> {
    let mut current_path = String::new();
    let mut found_cbt = false;

    for line in gitmodules_content.lines() {
        if line.starts_with("[submodule ") {
            current_path.clear();
            found_cbt = false;
        }
        if let Some(rest) = line.trim().strip_prefix("path") {
            let rest = rest.trim_start();
            if let Some(val) = rest.strip_prefix('=') {
                current_path = val.trim().to_string();
            }
        }
        if line.contains("url") && line.contains("c-build-tools") {
            found_cbt = true;
        }
        if found_cbt && !current_path.is_empty() {
            return Some(current_path);
        }
    }
    None
}

/// Determine expected SHA from git ls-tree, or use the provided override.
fn get_expected_sha(repo_root: &str, submodule_path: &str, sha_override: &Option<String>) -> Result<String, String> {
    if let Some(sha) = sha_override {
        return Ok(sha.clone());
    }

    let output = Command::new("git")
        .args(["-C", repo_root, "ls-tree", "HEAD", submodule_path])
        .output()
        .map_err(|e| format!("Failed to run git: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("git ls-tree failed: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Output format: "160000 commit <sha>\t<path>"
    for part in stdout.split_whitespace() {
        if part.len() == 40 && part.chars().all(|c| c.is_ascii_hexdigit()) {
            return Ok(part.to_string());
        }
    }

    Err(format!("Could not parse submodule SHA from: {}", stdout.trim()))
}

/// Recursively find all .yml files under a directory, respecting exclusions and
/// skipping hidden directories.
fn find_yml_files(dir: &Path, repo_root: &str, exclude_folders: &[String], out: &mut Vec<(String, String)>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    let root_len = repo_root.len();

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        if name_str.starts_with('.') {
            continue;
        }

        let full_path = entry.path();
        let full_path_str = full_path.to_string_lossy().to_string();

        let relative = if full_path_str.len() > root_len {
            let r = &full_path_str[root_len..];
            r.trim_start_matches(['/', '\\']).to_string()
        } else {
            name_str.to_string()
        };

        let ft = match entry.file_type() {
            Ok(ft) => ft,
            Err(_) => continue,
        };

        if ft.is_dir() {
            if !is_path_excluded(&relative, exclude_folders) {
                find_yml_files(&full_path, repo_root, exclude_folders, out);
            }
        } else if ft.is_file() && name_str.ends_with(".yml") && !is_path_excluded(&relative, exclude_folders) {
            out.push((full_path_str, relative));
        }
    }
}

/// Check if a trimmed YAML line is a c_build_tools repository declaration.
/// Matches with flexible whitespace: optional "-", then "repository:", then "c_build_tools"
/// Mirrors PS1 regex: '^\s*-?\s*repository:\s*c_build_tools\s*$'
fn is_cbt_repository_line(trimmed: &str) -> bool {
    let s = trimmed.trim_start_matches('-').trim();
    if let Some(rest) = s.strip_prefix("repository:") {
        rest.trim() == "c_build_tools"
    } else {
        false
    }
}

/// Check a single YAML file for c_build_tools repository ref.
/// Returns (is_valid, ref_line_index, ref_value) or None if file doesn't reference c_build_tools.
fn check_yaml_file(lines: &[String], expected_sha: &str) -> Option<(bool, usize, String)> {
    let mut in_cbt_block = false;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        // Match "repository: c_build_tools" with optional leading "- " and flexible whitespace
        // Pattern mirrors PS1: '^\s*-?\s*repository:\s*c_build_tools\s*$'
        if is_cbt_repository_line(trimmed) {
            in_cbt_block = true;
            continue;
        }

        if in_cbt_block {
            // Exit block on next repository definition or non-indented non-empty line
            if trimmed.starts_with("- repository:") {
                in_cbt_block = false;
                continue;
            }
            if !trimmed.is_empty() && !line.starts_with(' ') && !line.starts_with('\t') {
                in_cbt_block = false;
                continue;
            }

            if let Some(rest) = trimmed.strip_prefix("ref:") {
                let ref_value = rest.trim().to_string();
                let is_valid = if ref_value == "refs/heads/master" {
                    true
                } else if ref_value.len() == 40 && ref_value.chars().all(|c| c.is_ascii_hexdigit()) {
                    ref_value == expected_sha
                } else {
                    false
                };
                return Some((is_valid, i, ref_value));
            }
        }
    }

    None
}

impl Check for CBuildToolsRef {
    fn name(&self) -> &str {
        "c_build_tools_ref"
    }

    fn description(&self) -> &str {
        "Validates pipeline YAML files reference correct c-build-tools ref"
    }

    fn file_types(&self) -> u32 {
        // This check does its own file walking for .yml files
        0
    }

    fn requires_devdoc(&self) -> bool {
        false
    }

    fn init(&mut self, config: &ValidatorConfig) {
        self.violations = 0;
        self.fixed = 0;

        println!();
        println!("  ----------------------------------------");
        println!("  c-build-tools Ref Validation");
        println!("  ----------------------------------------");

        // Step 1: Find .gitmodules
        let gitmodules_path = format!("{}/.gitmodules", config.repo_root);
        let gitmodules_path_win = format!("{}\\.gitmodules", config.repo_root);

        let gitmodules_content = if let Ok(content) = fs::read_to_string(&gitmodules_path) {
            content
        } else if let Ok(content) = fs::read_to_string(&gitmodules_path_win) {
            content
        } else {
            println!("  No .gitmodules file found. Skipping (not applicable).");
            return;
        };

        // Step 2: Parse c-build-tools submodule path
        let submodule_path = match find_cbt_submodule_path(&gitmodules_content) {
            Some(p) => p,
            None => {
                println!("  No c-build-tools submodule found in .gitmodules. Skipping.");
                return;
            }
        };
        println!("  c-build-tools submodule path: {}", submodule_path);

        // Step 3: Get expected SHA
        let expected_sha = match get_expected_sha(&config.repo_root, &submodule_path, &config.submodule_sha) {
            Ok(sha) => sha,
            Err(e) => {
                println!("  [ERROR] {}", e);
                self.violations = 1;
                return;
            }
        };
        println!("  Expected submodule SHA: {}", expected_sha);

        // Step 4: Find all .yml files
        let mut yml_files: Vec<(String, String)> = Vec::new();
        find_yml_files(Path::new(&config.repo_root), &config.repo_root, &config.exclude_folders, &mut yml_files);

        // Step 5: Check each YAML file
        for (full_path, relative_path) in &yml_files {
            let content = match fs::read_to_string(full_path) {
                Ok(c) => c,
                Err(_) => {
                    println!("  [WARN] Cannot read file: {}", relative_path);
                    continue;
                }
            };

            // Quick check: does this file reference c_build_tools?
            // Uses flexible matching (mirrors PS1: 'repository:\s*c_build_tools')
            if !content.contains("c_build_tools") {
                continue;
            }

            let lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();

            let (is_valid, ref_line_idx, ref_value) = match check_yaml_file(&lines, &expected_sha) {
                Some(result) => result,
                None => {
                    println!("  [WARN] No ref: found for c_build_tools in {}", relative_path);
                    continue;
                }
            };

            if is_valid {
                if ref_value == "refs/heads/master" {
                    println!("  [OK]   {} (ref: refs/heads/master)", relative_path);
                } else {
                    println!(
                        "  [OK]   {} (ref: {}... matches submodule)",
                        relative_path,
                        &ref_value[..12.min(ref_value.len())]
                    );
                }
            } else {
                let reason = if ref_value.len() == 40 && ref_value.chars().all(|c| c.is_ascii_hexdigit()) {
                    format!(
                        "SHA mismatch: YAML has {}..., submodule is {}...",
                        &ref_value[..12.min(ref_value.len())],
                        &expected_sha[..12.min(expected_sha.len())]
                    )
                } else {
                    format!(
                        "Unexpected ref value: {} (expected refs/heads/master or a 40-char commit SHA)",
                        ref_value
                    )
                };

                println!("  [FAIL] {}", relative_path);
                println!("         {}", reason);

                if config.fix_mode {
                    // Replace the ref value with the expected SHA
                    let mut new_lines = lines.clone();
                    let old_line = &new_lines[ref_line_idx];
                    if let Some(ref_pos) = old_line.find("ref:") {
                        let prefix = &old_line[..ref_pos];
                        new_lines[ref_line_idx] = format!("{}ref: {}", prefix, expected_sha);

                        let new_content = new_lines.join("\n");
                        // Preserve original line ending: if original had trailing newline, keep it
                        let new_content = if content.ends_with('\n') {
                            format!("{}\n", new_content)
                        } else {
                            new_content
                        };

                        match fs::write(full_path, new_content.as_bytes()) {
                            Ok(_) => {
                                println!(
                                    "         [FIXED] Updated ref to {}...",
                                    &expected_sha[..12.min(expected_sha.len())]
                                );
                                self.fixed += 1;
                            }
                            Err(e) => {
                                println!("         [ERROR] Failed to fix: {}", e);
                                self.violations += 1;
                            }
                        }
                    } else {
                        self.violations += 1;
                    }
                } else {
                    self.violations += 1;
                }
            }
        }
    }

    fn check_file(&mut self, _file: &FileInfo, _config: &ValidatorConfig) {
        // No-op: this check does its own file walking for .yml files
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        if self.fixed > 0 {
            println!("  Files fixed: {}", self.fixed);
        }
        self.violations
    }
}
