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

#[derive(Clone, Copy)]
enum RefKind {
    PipelineRepository,
    GithubUses,
}

struct RefOccurrence {
    line_index: usize,
    ref_value: String,
    kind: RefKind,
}

struct YamlFile {
    full_path: String,
    relative_path: String,
    content: String,
    lines: Vec<String>,
    refs: Vec<RefOccurrence>,
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
fn get_expected_sha(
    repo_root: &str,
    submodule_path: &str,
    sha_override: &Option<String>,
) -> Result<String, String> {
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

    Err(format!(
        "Could not parse submodule SHA from: {}",
        stdout.trim()
    ))
}

/// Recursively find YAML files, respecting exclusions. Hidden directories are skipped
/// except for .github, which contains executable GitHub Actions configuration.
fn find_yaml_files(
    dir: &Path,
    repo_root: &str,
    exclude_folders: &[String],
    out: &mut Vec<(String, String)>,
) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    let root_len = repo_root.len();

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let full_path = entry.path();
        let full_path_str = full_path.to_string_lossy().to_string();

        let relative = if full_path_str.len() > root_len {
            let r = &full_path_str[root_len..];
            r.trim_start_matches(['/', '\\']).to_string()
        } else {
            name_str.to_string()
        };

        // The c-build-tools repository contains intentionally-invalid fixtures. They are
        // still scanned when each fixture is supplied as the repository root.
        let normalized_relative = relative.replace('\\', "/").to_ascii_lowercase();
        if normalized_relative.starts_with("repo_validation/tests/validate_c_build_tools_ref/")
            || normalized_relative == "repo_validation/tests/validate_c_build_tools_ref"
        {
            continue;
        }

        let ft = match entry.file_type() {
            Ok(ft) => ft,
            Err(_) => continue,
        };

        if ft.is_dir() {
            if name_str.starts_with('.') && name_str.as_ref() != ".github" {
                continue;
            }
            if !is_path_excluded(&relative, exclude_folders) {
                find_yaml_files(&full_path, repo_root, exclude_folders, out);
            }
        } else if ft.is_file() && !is_path_excluded(&relative, exclude_folders) {
            let lower_name = name_str.to_ascii_lowercase();
            if lower_name.ends_with(".yml") || lower_name.ends_with(".yaml") {
                out.push((full_path_str, relative));
            }
        }
    }
}

fn parse_yaml_scalar(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix('"') {
        rest.split('"').next().unwrap_or("").to_string()
    } else if let Some(rest) = trimmed.strip_prefix('\'') {
        rest.split('\'').next().unwrap_or("").to_string()
    } else {
        trimmed.split('#').next().unwrap_or("").trim().to_string()
    }
}

/// Check if a trimmed YAML line is a repository declaration.
fn is_repository_line(trimmed: &str) -> bool {
    trimmed
        .trim_start_matches('-')
        .trim()
        .starts_with("repository:")
}

/// Check if a trimmed YAML line is a c_build_tools repository declaration.
fn is_cbt_repository_line(trimmed: &str) -> bool {
    let s = trimmed.trim_start_matches('-').trim();
    if let Some(rest) = s.strip_prefix("repository:") {
        rest.trim() == "c_build_tools"
    } else {
        false
    }
}

fn find_pipeline_refs(lines: &[String]) -> Vec<RefOccurrence> {
    let mut refs = Vec::new();
    let mut in_cbt_block = false;

    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();

        if is_cbt_repository_line(trimmed) {
            in_cbt_block = true;
            continue;
        }

        if in_cbt_block {
            if is_repository_line(trimmed) {
                in_cbt_block = false;
                continue;
            }
            if !trimmed.is_empty() && !line.starts_with(' ') && !line.starts_with('\t') {
                in_cbt_block = false;
                continue;
            }

            if let Some(rest) = trimmed.strip_prefix("ref:") {
                refs.push(RefOccurrence {
                    line_index: i,
                    ref_value: parse_yaml_scalar(rest),
                    kind: RefKind::PipelineRepository,
                });
                in_cbt_block = false;
            }
        }
    }

    refs
}

fn is_github_actions_config(relative_path: &str) -> bool {
    let normalized = relative_path.replace('\\', "/").to_ascii_lowercase();
    normalized.starts_with(".github/workflows/")
        || normalized == "action.yml"
        || normalized == "action.yaml"
        || normalized.ends_with("/action.yml")
        || normalized.ends_with("/action.yaml")
}

fn find_github_uses_refs(lines: &[String]) -> Vec<RefOccurrence> {
    let mut refs = Vec::new();

    for (i, line) in lines.iter().enumerate() {
        let mut trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix('-') {
            trimmed = rest.trim_start();
        }

        let Some(rest) = trimmed.strip_prefix("uses:") else {
            continue;
        };

        let target = parse_yaml_scalar(rest);
        if !target
            .to_ascii_lowercase()
            .starts_with("azure/c-build-tools/")
        {
            continue;
        }

        let ref_value = target
            .rsplit_once('@')
            .map(|(_, value)| value.to_string())
            .unwrap_or_default();

        refs.push(RefOccurrence {
            line_index: i,
            ref_value,
            kind: RefKind::GithubUses,
        });
    }

    refs
}

fn find_cbt_refs(lines: &[String], relative_path: &str) -> Vec<RefOccurrence> {
    let mut refs = find_pipeline_refs(lines);
    if is_github_actions_config(relative_path) {
        refs.extend(find_github_uses_refs(lines));
    }
    refs
}

fn replace_ref_in_line(
    line: &str,
    occurrence: &RefOccurrence,
    expected_sha: &str,
) -> Option<String> {
    if occurrence.ref_value.is_empty() {
        return None;
    }

    let (start, end) = match occurrence.kind {
        RefKind::PipelineRepository => {
            let marker = line.find("ref:")?;
            let after_marker = marker + "ref:".len();
            let remaining = &line[after_marker..];
            let whitespace_len = remaining.len() - remaining.trim_start().len();
            let mut start = after_marker + whitespace_len;

            if start < line.len() {
                let first = line.as_bytes()[start];
                if first == b'\'' || first == b'"' {
                    start += 1;
                }
            }

            if !line[start..].starts_with(&occurrence.ref_value) {
                return None;
            }
            (start, start + occurrence.ref_value.len())
        }
        RefKind::GithubUses => {
            let uses_position = line.find("uses:")?;
            let needle = format!("@{}", occurrence.ref_value);
            let relative = line[uses_position..].find(&needle)?;
            let start = uses_position + relative + 1;
            (start, start + occurrence.ref_value.len())
        }
    };

    let mut updated = String::with_capacity(line.len() + expected_sha.len());
    updated.push_str(&line[..start]);
    updated.push_str(expected_sha);
    updated.push_str(&line[end..]);
    Some(updated)
}

fn ref_kind_label(kind: RefKind) -> &'static str {
    match kind {
        RefKind::PipelineRepository => "pipeline repository ref",
        RefKind::GithubUses => "GitHub Actions uses ref",
    }
}

fn mismatch_reason(ref_value: &str, expected_sha: &str) -> String {
    if ref_value.is_empty() {
        format!("Missing @ref (expected submodule SHA {})", expected_sha)
    } else if ref_value.len() == 40 && ref_value.chars().all(|c| c.is_ascii_hexdigit()) {
        format!(
            "SHA mismatch: YAML has {}..., submodule is {}...",
            &ref_value[..12.min(ref_value.len())],
            &expected_sha[..12.min(expected_sha.len())]
        )
    } else {
        format!(
            "Ref {} does not match c-build-tools submodule SHA {}...",
            ref_value,
            &expected_sha[..12.min(expected_sha.len())]
        )
    }
}

impl Check for CBuildToolsRef {
    fn name(&self) -> &str {
        "c_build_tools_ref"
    }

    fn description(&self) -> &str {
        "Validates c-build-tools YAML refs match the submodule SHA"
    }

    fn file_types(&self) -> u32 {
        // This check does its own YAML file walking.
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

        let mut yaml_paths: Vec<(String, String)> = Vec::new();
        find_yaml_files(
            Path::new(&config.repo_root),
            &config.repo_root,
            &config.exclude_folders,
            &mut yaml_paths,
        );

        let mut files_with_refs = Vec::new();
        for (full_path, relative_path) in yaml_paths {
            let content = match fs::read_to_string(&full_path) {
                Ok(content) => content,
                Err(_) => {
                    println!("  [WARN] Cannot read file: {}", relative_path);
                    continue;
                }
            };
            let lines: Vec<String> = content.lines().map(|line| line.to_string()).collect();
            let refs = find_cbt_refs(&lines, &relative_path);
            if !refs.is_empty() {
                files_with_refs.push(YamlFile {
                    full_path,
                    relative_path,
                    content,
                    lines,
                    refs,
                });
            }
        }

        let gitmodules_path = format!("{}/.gitmodules", config.repo_root);
        let gitmodules_path_win = format!("{}\\.gitmodules", config.repo_root);
        let gitmodules_content = fs::read_to_string(&gitmodules_path)
            .or_else(|_| fs::read_to_string(&gitmodules_path_win))
            .ok();
        let submodule_path = gitmodules_content
            .as_deref()
            .and_then(find_cbt_submodule_path);

        let Some(submodule_path) = submodule_path else {
            if files_with_refs.is_empty() {
                println!("  No c-build-tools submodule or references found. Skipping.");
            } else {
                for file in &files_with_refs {
                    for reference in &file.refs {
                        println!(
                            "  [FAIL] {}:{}",
                            file.relative_path,
                            reference.line_index + 1
                        );
                        println!(
                            "         {} exists, but no c-build-tools submodule was found",
                            ref_kind_label(reference.kind)
                        );
                        self.violations += 1;
                    }
                }
            }
            return;
        };
        println!("  c-build-tools submodule path: {}", submodule_path);

        let expected_sha =
            match get_expected_sha(&config.repo_root, &submodule_path, &config.submodule_sha) {
                Ok(sha) => sha,
                Err(error) => {
                    println!("  [ERROR] {}", error);
                    self.violations = 1;
                    return;
                }
            };
        println!("  Expected submodule SHA: {}", expected_sha);

        for file in files_with_refs {
            let mut updated_lines = file.lines.clone();
            let mut fixes_in_file = 0;
            let mut replacement_failures = 0;

            for reference in &file.refs {
                if reference.ref_value == expected_sha {
                    println!(
                        "  [OK]   {}:{} ({} matches submodule)",
                        file.relative_path,
                        reference.line_index + 1,
                        ref_kind_label(reference.kind)
                    );
                    continue;
                }

                println!(
                    "  [FAIL] {}:{}",
                    file.relative_path,
                    reference.line_index + 1
                );
                println!(
                    "         {}: {}",
                    ref_kind_label(reference.kind),
                    mismatch_reason(&reference.ref_value, &expected_sha)
                );

                if config.fix_mode {
                    match replace_ref_in_line(
                        &updated_lines[reference.line_index],
                        reference,
                        &expected_sha,
                    ) {
                        Some(updated_line) => {
                            updated_lines[reference.line_index] = updated_line;
                            fixes_in_file += 1;
                        }
                        None => {
                            println!("         [ERROR] Could not rewrite the ref");
                            replacement_failures += 1;
                        }
                    }
                } else {
                    self.violations += 1;
                }
            }

            self.violations += replacement_failures;
            if fixes_in_file == 0 {
                continue;
            }

            let newline = if file.content.contains("\r\n") {
                "\r\n"
            } else {
                "\n"
            };
            let mut new_content = updated_lines.join(newline);
            if file.content.ends_with('\n') {
                new_content.push_str(newline);
            }

            match fs::write(&file.full_path, new_content.as_bytes()) {
                Ok(_) => {
                    println!(
                        "         [FIXED] Updated {} reference(s) to {}...",
                        fixes_in_file,
                        &expected_sha[..12.min(expected_sha.len())]
                    );
                    self.fixed += fixes_in_file;
                }
                Err(error) => {
                    println!(
                        "         [ERROR] Failed to write {}: {}",
                        file.relative_path, error
                    );
                    self.violations += fixes_in_file;
                }
            }
        }
    }

    fn check_file(&mut self, _file: &FileInfo, _config: &ValidatorConfig) {
        // No-op: this check does its own YAML file walking.
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        if self.fixed > 0 {
            println!("  References fixed: {}", self.fixed);
        }
        self.violations
    }
}
