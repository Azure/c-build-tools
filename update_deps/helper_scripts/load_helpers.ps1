# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Loads every propagation helper once, in dependency order. Dot-source this file; the helpers only
# define functions and initialize module state, so the caller's variables are left untouched.

$helper_script_names = @(
    'logging.ps1',
    'check_powershell_version.ps1',
    'check_script_update.ps1',
    'install_az_cli.ps1',
    'install_gh_cli.ps1',
    'pipeline_environment.ps1',
    'status_tracking.ps1',
    'propagation_state.ps1',
    'git_operations.ps1',
    'build_graph.ps1',
    'pr_watch_utils.ps1',
    'watch_azure_pr.ps1',
    'watch_github_pr.ps1',
    'azure_repo_ops.ps1',
    'github_repo_ops.ps1',
    'preflight.ps1',
    'autofix.ps1',
    'success_animation.ps1',
    'update_repo.ps1'
)

foreach ($helper_script_name in $helper_script_names)
{
    . (Join-Path $PSScriptRoot $helper_script_name)
}
