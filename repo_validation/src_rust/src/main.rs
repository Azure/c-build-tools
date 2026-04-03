// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

mod checks;
mod config;
mod file_walker;

use config::ValidatorConfig;
use std::process;

fn print_usage(program_name: &str) {
    println!("Usage: {} --repo-root <path> [options]\n", program_name);
    println!("Options:");
    println!("  --repo-root <path>        Repository root directory (required)");
    println!("  --exclude-folders <list>   Comma-separated list of folders to exclude");
    println!("  --fix                      Automatically fix validation errors");
    println!("  --check <name>             Run only the specified check (can be repeated)");
    println!("  --list-checks              List all available checks");
    println!("  --help                     Show this help message");
    println!("\nAvailable checks:");
    println!("  no_tabs                    Validates files contain no tab characters");
    println!("  file_endings               Validates files end with CRLF newline");
    println!("  requirements_naming        Validates requirement document naming");
    println!("  srs_uniqueness             Validates SRS tags are unique");
    println!("  enable_mocks               Validates ENABLE_MOCKS include pattern");
    println!("  no_vld_include             Validates files do not include vld.h");
    println!("  no_backticks_in_srs        Validates SRS comments have no backticks");
    println!("  test_spec_tags             Validates TEST_FUNCTION has spec tags");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let program_name = &args[0];

    let all_checks = checks::all_checks();

    let mut repo_root: Option<String> = None;
    let mut exclude_str = String::new();
    let mut fix_mode = false;
    let mut enabled_check_names: Vec<String> = Vec::new();
    let mut list_checks = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--repo-root" | "-RepoRoot" => {
                if i + 1 < args.len() {
                    i += 1;
                    repo_root = Some(args[i].clone());
                }
            }
            "--exclude-folders" | "-ExcludeFolders" => {
                if i + 1 < args.len() {
                    i += 1;
                    exclude_str = args[i].clone();
                }
            }
            "--fix" | "-Fix" => {
                fix_mode = true;
            }
            "--check" => {
                if i + 1 < args.len() {
                    i += 1;
                    enabled_check_names.push(args[i].clone());
                }
            }
            "--list-checks" => {
                list_checks = true;
            }
            "--help" | "-h" => {
                print_usage(program_name);
                process::exit(0);
            }
            _ => {}
        }
        i += 1;
    }

    if list_checks {
        println!("Available checks:");
        for check in &all_checks {
            println!("  {:<25} {}", check.name(), check.description());
        }
        process::exit(0);
    }

    let repo_root = match repo_root {
        Some(r) => r,
        None => {
            eprintln!("Error: --repo-root is required\n");
            print_usage(program_name);
            process::exit(1);
        }
    };

    // Normalize repo_root: strip trailing separator
    let repo_root = repo_root.trim_end_matches(['/', '\\']).to_string();

    // Parse exclude folders - always include deps and cmake as defaults
    let mut exclude_folders: Vec<String> = vec!["deps".to_string(), "cmake".to_string()];

    if !exclude_str.is_empty() {
        for tok in exclude_str.split(',') {
            let trimmed = tok.trim();
            if !trimmed.is_empty() && trimmed != "deps" && trimmed != "cmake" {
                exclude_folders.push(trimmed.to_string());
            }
        }
    }

    let config = ValidatorConfig {
        repo_root,
        exclude_folders,
        fix_mode,
    };

    // Select active checks
    let mut active_checks: Vec<Box<dyn checks::Check>> = Vec::new();
    for check in all_checks {
        if enabled_check_names.is_empty()
            || enabled_check_names.iter().any(|name| name == check.name())
        {
            active_checks.push(check);
        }
    }

    if active_checks.is_empty() {
        eprintln!("Error: no matching checks found");
        process::exit(1);
    }

    // Print header
    println!("========================================");
    println!("Repository Validator");
    println!("========================================");
    println!("Repository Root: {}", config.repo_root);
    println!("Fix Mode: {}", if config.fix_mode { "ON" } else { "OFF" });
    print!("Excluded folders: ");
    for (idx, folder) in config.exclude_folders.iter().enumerate() {
        if idx > 0 {
            print!(", ");
        }
        print!("{}", folder);
    }
    println!();
    print!("Active checks: ");
    for (idx, check) in active_checks.iter().enumerate() {
        if idx > 0 {
            print!(", ");
        }
        print!("{}", check.name());
    }
    println!("\n");

    // Initialize checks
    for check in active_checks.iter_mut() {
        check.init(&config);
    }

    // Walk repository and run checks
    println!("Scanning repository...");
    file_walker::walk_repository(&config, &mut active_checks);

    // Finalize checks
    let mut total_violations = 0;
    println!();
    println!("========================================");
    println!("Validation Summary");
    println!("========================================");

    for check in active_checks.iter_mut() {
        let check_result = check.finalize(&config);
        let status = if check_result == 0 {
            "PASSED"
        } else {
            "FAILED"
        };
        println!("  {:<25} [{}]", check.name(), status);
        if check_result > 0 {
            total_violations += check_result;
        }
    }

    println!();
    if total_violations > 0 {
        println!("[VALIDATION FAILED]");
        process::exit(1);
    } else {
        println!("[VALIDATION PASSED]");
        process::exit(0);
    }
}
