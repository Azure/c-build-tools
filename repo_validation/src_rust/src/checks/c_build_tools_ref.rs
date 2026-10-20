// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use crate::checks::Check;
use crate::config::*;
use crate::file_walker::is_path_excluded;
use saphyr::{LoadableYamlNode, MarkedYaml};
use std::fs;
use std::ops::Range;
use std::path::Path;
use std::process::Command;

pub struct CBuildToolsRef {
    violations: i32,
    fixed: i32,
}

struct RefOccurrence {
    line: usize,
    target: String,
    span: Range<usize>,
}

impl CBuildToolsRef {
    pub fn new() -> Self {
        Self {
            violations: 0,
            fixed: 0,
        }
    }
}

/// Both the canonical dependency path and the repository URL must match.
fn find_cbt_submodule_path(gitmodules_content: &str) -> Option<String> {
    let mut current_path = String::new();
    let mut found_cbt = false;

    for line in gitmodules_content.lines().chain(std::iter::once("[end]")) {
        let line = line.trim();
        if line.starts_with('[') {
            if current_path == "deps/c-build-tools" && found_cbt {
                return Some(current_path);
            }
            current_path.clear();
            found_cbt = false;
        }
        if let Some((key, value)) = line.split_once('=') {
            let value = value.trim().trim_matches('"');
            match key.trim() {
                "path" => current_path = value.to_string(),
                "url" => found_cbt = matches!(
                    value.trim_end_matches('/').trim_end_matches(".git").to_ascii_lowercase().as_str(),
                    "https://github.com/azure/c-build-tools" | "git@github.com:azure/c-build-tools"
                        | "ssh://git@github.com/azure/c-build-tools"
                ),
                _ => {}
            }
        }
    }
    None
}

/// Determine expected SHA from git ls-tree, or use the provided test override.
fn get_expected_sha(repo_root: &str, submodule_path: &str, sha_override: &Option<String>) -> Result<String, String> {
    if let Some(sha) = sha_override {
        return Ok(sha.clone());
    }

    let output = Command::new("git")
        .args(["-C", repo_root, "ls-tree", "HEAD", submodule_path])
        .output()
        .map_err(|e| format!("Failed to run git: {}", e))?;

    if !output.status.success() {
        return Err(format!("git ls-tree failed: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = stdout.split_whitespace().collect();
    if parts.len() == 4 && parts[0] == "160000" && parts[1] == "commit"
        && parts[3] == submodule_path && parts[2].len() == 40
        && parts[2].chars().all(|c| c.is_ascii_hexdigit()) {
        return Ok(parts[2].to_string());
    }
    Err("deps/c-build-tools is not a gitlink in HEAD".to_string())
}

/// Find workflow and action metadata YAML, respecting exclusions (including hidden actions).
fn find_yml_files(dir: &Path, repo_root: &str, exclude_folders: &[String], out: &mut Vec<(String, String)>) -> Result<(), String> {
    for entry in fs::read_dir(dir).map_err(|e| format!("Cannot scan {}: {}", dir.display(), e))? {
        let entry = entry.map_err(|e| format!("Cannot read directory entry: {}", e))?;
        let full_path = entry.path();
        let relative = full_path.strip_prefix(repo_root).map_err(|e| e.to_string())?
            .to_string_lossy().to_string();
        let normalized = relative.replace('\\', "/");
        // Fixtures are checked with each fixture as its own repository root.
        if normalized == "repo_validation/tests/validate_c_build_tools_ref"
            || normalized == ".git" || normalized.ends_with("/.git")
            || is_path_excluded(&relative, exclude_folders) {
            continue;
        }
        let ft = entry.file_type().map_err(|e| format!("Cannot inspect {}: {}", relative, e))?;
        if ft.is_dir() {
            find_yml_files(&full_path, repo_root, exclude_folders, out)?;
        } else if ft.is_file() && is_actions_file(&normalized) {
            out.push((full_path.to_string_lossy().to_string(), relative));
        }
    }
    Ok(())
}

fn is_actions_file(path: &str) -> bool {
    !path.starts_with(".github/workflow-templates/") && (
        (path.starts_with(".github/workflows/") && (path.ends_with(".yml") || path.ends_with(".yaml")))
        || matches!(path.rsplit('/').next(), Some("action.yml" | "action.yaml"))
    )
}

fn child<'a, 'input>(node: &'a MarkedYaml<'input>, key: &str) -> Option<&'a MarkedYaml<'input>> {
    node.data.as_mapping()?.iter().find_map(|(k, v)| (k.data.as_str() == Some(key)).then_some(v))
}

fn find_cbt_refs(content: &str, path: &str) -> Result<Vec<RefOccurrence>, String> {
    let mut refs = Vec::new();
    // Iterator-input markers count characters; edits need UTF-8 byte offsets.
    let offsets: Vec<_> = content.char_indices().map(|(offset, _)| offset).chain(std::iter::once(content.len())).collect();
    for doc in MarkedYaml::load_from_iter(content.chars()).map_err(|e| format!("Invalid YAML: {}", e))? {
        let mut uses = Vec::new();
        let containers: Vec<_> = if path.replace('\\', "/").starts_with(".github/workflows/") {
            child(&doc, "jobs").and_then(|jobs| jobs.data.as_mapping())
                .map(|jobs| jobs.values().collect()).unwrap_or_default()
        } else {
            child(&doc, "runs").filter(|runs|
                child(runs, "using").and_then(|using| using.data.as_str()) == Some("composite")
            ).into_iter().collect()
        };
        for container in containers {
            uses.extend(child(container, "uses"));
            if let Some(steps) = child(container, "steps").and_then(|steps| steps.data.as_vec()) {
                uses.extend(steps.iter().filter_map(|step| child(step, "uses")));
            }
        }
        for node in uses {
            if let Some(target) = node.data.as_str() {
                if target.to_ascii_lowercase().starts_with("azure/c-build-tools/") {
                    refs.push(RefOccurrence {
                        line: node.span.start.line(),
                        target: target.to_string(),
                        span: offsets[node.span.start.index()]..offsets[node.span.end.index()],
                    });
                }
            }
        }
    }
    refs.sort_by_key(|reference| reference.span.start);
    refs.dedup_by_key(|reference| reference.span.start);
    Ok(refs)
}

// Edit only the literal ref within the parsed scalar, never reserialize YAML.
fn replace_ref(content: &mut String, reference: &RefOccurrence, sha: &str) -> Result<(), String> {
    let raw = &content[reference.span.clone()];
    let ref_value = reference.target.rsplit_once('@').map(|(_, value)| value)
        .ok_or_else(|| "Missing @ref; update the uses value manually".to_string())?;
    if ref_value.chars().any(char::is_whitespace) {
        return Err("Whitespace in ref; update the uses value manually".to_string());
    }
    let start = raw.find('@').map(|index| index + 1)
        .filter(|&index| raw[index..].starts_with(ref_value))
        .ok_or_else(|| "Cannot safely locate literal ref; update the uses value manually".to_string())?;
    let start = reference.span.start + start;
    content.replace_range(start..start + ref_value.len(), sha);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const SHA: &str = "aabbccdd00112233445566778899aabbccddeeff";

    #[test]
    fn source_span_fixes_preserve_every_other_byte() {
        for raw in [
            "Azure/c-build-tools/actions/test@refs/heads/feature#1",
            "'Azure/c-build-tools/actions/test@v1'",
            "\"Azure/c-build-tools/actions/test@master\"",
            "\"Azure\\/c-build-tools/actions/test@master\"",
        ] {
            let mut text = format!("name: \u{03a9}\r\njobs:\r\n  test:\r\n    uses: {} # keep\r\n", raw);
            let refs = find_cbt_refs(&text, ".github/workflows/test.yml").unwrap();
            assert_eq!(refs.len(), 1);
            assert_eq!(refs[0].line, 4);
            replace_ref(&mut text, &refs[0], SHA).unwrap();
            let quote = if raw.starts_with('\'') { "'" } else if raw.starts_with('"') { "\"" } else { "" };
            let prefix = if raw.contains("\\/") { "Azure\\/c-build-tools" } else { "Azure/c-build-tools" };
            assert_eq!(text, format!("name: \u{03a9}\r\njobs:\r\n  test:\r\n    uses: {}{}/actions/test@{}{} # keep\r\n", quote, prefix, SHA, quote));
        }
    }

    #[test]
    fn yaml_structure_selects_only_executable_uses() {
        let content = "description: |\n  uses: Azure/c-build-tools/actions/test@text\njobs:\n  test:\n    env: {uses: Azure/c-build-tools/actions/test@env}\n    steps:\n      - run: |\n          uses: Azure/c-build-tools/actions/test@script\n      - {uses: Azure/c-build-tools/actions/test@master}\n      - {uses: 'Azure/c-build-tools/actions/test@v1'}\n";
        assert_eq!(find_cbt_refs(content, ".github/workflows/test.yml").unwrap().len(), 2);
        let action = "runs: {using: composite, steps: [{uses: Azure/c-build-tools/actions/test@master}]}";
        assert_eq!(find_cbt_refs(action, ".ci/action.yml").unwrap().len(), 1);
        assert!(find_cbt_refs(&action.replace("composite", "node20"), "action.yml").unwrap().is_empty());
        assert!(find_cbt_refs("runs: [", "action.yml").is_err());
    }

    #[test]
    fn fixes_refuse_nonliteral_or_multiline_values_without_changing_source() {
        for content in [
            "pin: &pin Azure/c-build-tools/actions/test@master\njobs: {test: {uses: *pin}}\n",
            "jobs: {test: {uses: \"Azure/c-build-tools/actions/test@\\x6daster\"}}\n",
            "jobs:\n  test:\n    uses: |\n      Azure/c-build-tools/actions/test@master\n    name: keep\n",
        ] {
            let refs = find_cbt_refs(content, ".github/workflows/test.yml").unwrap();
            assert_eq!(refs.len(), 1);
            let mut updated = content.to_string();
            assert!(replace_ref(&mut updated, &refs[0], SHA).is_err());
            assert_eq!(updated, content);
        }
    }

    #[test]
    fn submodule_requires_exact_path_and_url() {
        for url in ["https://github.com/Azure/c-build-tools", "https://github.com/Azure/c-build-tools.git", "git@github.com:Azure/c-build-tools.git"] {
            let modules = format!("[submodule \"tools\"]\n url = {}\n path = deps/c-build-tools\n", url);
            assert_eq!(find_cbt_submodule_path(&modules).as_deref(), Some("deps/c-build-tools"));
            assert!(find_cbt_submodule_path(&modules.replace("deps/c-build-tools", "other/tools")).is_none());
            assert!(find_cbt_submodule_path(&modules.replace("Azure/c-build-tools", "other/c-build-tools")).is_none());
        }
        assert!(find_cbt_submodule_path("[submodule \"one\"]\n url = https://github.com/Azure/c-build-tools\n[submodule \"two\"]\n path = deps/c-build-tools\n").is_none());
    }
}

impl Check for CBuildToolsRef {
    fn name(&self) -> &str {
        "c_build_tools_ref"
    }

    fn description(&self) -> &str {
        "Validates GitHub Actions c-build-tools refs match deps/c-build-tools"
    }

    fn file_types(&self) -> u32 {
        // This check does its own file walking for workflow and action YAML.
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

        let expected_sha = fs::read_to_string(Path::new(&config.repo_root).join(".gitmodules"))
            .map_err(|e| format!("Cannot read .gitmodules: {}", e))
            .and_then(|modules| find_cbt_submodule_path(&modules)
                .ok_or_else(|| "No matching deps/c-build-tools submodule".to_string()))
            .and_then(|path| get_expected_sha(&config.repo_root, &path, &config.submodule_sha));
        let mut yml_files = Vec::new();
        if let Err(error) = find_yml_files(Path::new(&config.repo_root), &config.repo_root, &config.exclude_folders, &mut yml_files) {
            println!("  [ERROR] {}", error);
            self.violations += 1;
        }

        for (full_path, relative_path) in yml_files {
            let result = fs::read_to_string(&full_path).map_err(|e| e.to_string())
                .and_then(|content| find_cbt_refs(&content, &relative_path).map(|refs| (content, refs)));
            let (mut content, refs) = match result {
                Ok(file) => file,
                Err(error) => {
                    println!("  [ERROR] {}: {}", relative_path, error);
                    self.violations += 1;
                    continue;
                }
            };
            let mut fixes = 0;
            // Reverse source order keeps earlier spans valid as refs change length.
            for reference in refs.iter().rev() {
                let sha = match &expected_sha {
                    Ok(sha) => sha,
                    Err(error) => {
                        println!("  [FAIL] {}:{}: uses ref '{}' has no matching deps/c-build-tools gitlink: {}",
                            relative_path, reference.line, reference.target, error);
                        self.violations += 1;
                        continue;
                    }
                };
                if reference.target.rsplit_once('@').map(|(_, value)| value) == Some(sha.as_str()) {
                    println!("  [OK]   {}:{} (ref matches submodule)", relative_path, reference.line);
                    continue;
                }
                println!("  [FAIL] {}:{}: uses '{}' must match submodule SHA {}", relative_path, reference.line, reference.target, sha);
                if config.fix_mode {
                    match replace_ref(&mut content, reference, sha) {
                        Ok(()) => fixes += 1,
                        Err(error) => {
                            println!("  [ERROR] {}:{}: {}", relative_path, reference.line, error);
                            self.violations += 1;
                        }
                    }
                } else {
                    self.violations += 1;
                }
            }
            if fixes > 0 {
                match fs::write(&full_path, content) {
                    Ok(_) => {
                        println!("  [FIXED] {}: updated {} reference(s)", relative_path, fixes);
                        self.fixed += fixes;
                    }
                    Err(error) => {
                        println!("  [ERROR] {}: {}", relative_path, error);
                        self.violations += fixes;
                    }
                }
            }
        }
    }

    fn check_file(&mut self, _file: &FileInfo, _config: &ValidatorConfig) {
        // No-op: this check does its own file walking for workflow and action YAML.
    }

    fn finalize(&mut self, _config: &ValidatorConfig) -> i32 {
        if self.fixed > 0 {
            println!("  References fixed: {}", self.fixed);
        }
        self.violations
    }
}
