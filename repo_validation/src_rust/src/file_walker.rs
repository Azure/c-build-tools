// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

use std::fs;
use std::path::{Path, MAIN_SEPARATOR};

use crate::checks::Check;
use crate::config::*;

pub fn classify_file_type(filename: &str) -> u32 {
    if let Some(dot_pos) = filename.rfind('.') {
        match &filename[dot_pos..] {
            ".c" => FILE_TYPE_C,
            ".h" => FILE_TYPE_H,
            ".cpp" => FILE_TYPE_CPP,
            ".hpp" => FILE_TYPE_HPP,
            ".cs" => FILE_TYPE_CS,
            ".md" => FILE_TYPE_MD,
            ".txt" => FILE_TYPE_TXT,
            _ => 0,
        }
    } else {
        0
    }
}

pub fn is_in_devdoc_directory(relative_path: &str) -> bool {
    // Split path into components and check if any component is "devdoc"
    // and the file is a direct child of that devdoc directory
    let parts: Vec<&str> = relative_path.split(|c| c == '/' || c == '\\').collect();
    for (i, part) in parts.iter().enumerate() {
        if *part == "devdoc" && i + 1 < parts.len() {
            // Check if the next component is the last (i.e., the filename)
            if i + 2 == parts.len() {
                return true;
            }
        }
    }
    false
}

pub fn is_path_excluded(relative_path: &str, exclude_folders: &[String]) -> bool {
    for folder in exclude_folders {
        if folder.is_empty() {
            continue;
        }
        if relative_path.starts_with(folder.as_str()) {
            let rest = &relative_path[folder.len()..];
            if rest.is_empty()
                || rest.starts_with(MAIN_SEPARATOR)
                || rest.starts_with('/')
                || rest.starts_with('\\')
            {
                return true;
            }
        }
    }
    false
}

pub fn walk_repository(config: &ValidatorConfig, checks: &mut [Box<dyn Check>]) {
    walk_directory_recursive(config, checks, Path::new(&config.repo_root));
}

fn walk_directory_recursive(
    config: &ValidatorConfig,
    checks: &mut [Box<dyn Check>],
    dir: &Path,
) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };

        let file_name = entry.file_name();
        let name_str = file_name.to_string_lossy();

        // Skip hidden directories/files (starting with '.')
        if name_str.starts_with('.') {
            continue;
        }

        let full_path = entry.path();
        let full_path_str = full_path.to_string_lossy().to_string();

        // Compute relative path
        let relative = if full_path_str.len() > config.repo_root.len() {
            let r = &full_path_str[config.repo_root.len()..];
            if r.starts_with(MAIN_SEPARATOR) || r.starts_with('/') || r.starts_with('\\') {
                &r[1..]
            } else {
                r
            }
        } else {
            &name_str
        };
        let relative = relative.to_string();

        let file_type = match entry.file_type() {
            Ok(ft) => ft,
            Err(_) => continue,
        };

        if file_type.is_dir() {
            if !is_path_excluded(&relative, &config.exclude_folders) {
                walk_directory_recursive(config, checks, &full_path);
            }
        } else if file_type.is_file() {
            if !is_path_excluded(&relative, &config.exclude_folders) {
                process_file(config, checks, &full_path_str, &relative);
            }
        }
    }
}

fn process_file(
    config: &ValidatorConfig,
    checks: &mut [Box<dyn Check>],
    full_path: &str,
    relative_path: &str,
) {
    // Extract filename
    let filename = if let Some(pos) = full_path.rfind(MAIN_SEPARATOR) {
        &full_path[pos + 1..]
    } else if let Some(pos) = full_path.rfind('/') {
        &full_path[pos + 1..]
    } else {
        full_path
    };

    let file_type = classify_file_type(filename);
    if file_type == 0 {
        return;
    }

    let in_devdoc = is_in_devdoc_directory(relative_path);

    let mut flags = file_type;
    if in_devdoc {
        flags |= FILE_FLAG_IN_DEVDOC;
    }

    // Check if filename contains _ut.c or _ut.
    if filename.contains("_ut.c") || filename.contains("_ut.") {
        flags |= FILE_FLAG_IS_UT;
    }

    // Determine if any active check needs this file
    let needed = checks.iter().any(|check| {
        if check.requires_devdoc() && !in_devdoc {
            return false;
        }
        if check.file_types() & file_type == 0 {
            return false;
        }
        true
    });

    if !needed {
        return;
    }

    // Read file content
    let content = match fs::read(full_path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let file_info = FileInfo {
        path: full_path.to_string(),
        relative_path: relative_path.to_string(),
        type_flags: flags,
        content,
    };

    for check in checks.iter_mut() {
        if check.requires_devdoc() && !in_devdoc {
            continue;
        }
        if check.file_types() & file_type == 0 {
            continue;
        }
        check.check_file(&file_info, config);
    }
}
