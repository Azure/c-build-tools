# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
Functions for caching and retrieving repository order for dependency propagation.

.DESCRIPTION
Provides caching of the repository order along with the root_list that was used to generate it.
The cache is stored in the PROPAGATE_REPO_ORDER environment variable as JSON.
Cache is only valid if the root_list matches exactly.
#>

$script:CACHE_ENV_VAR = "PROPAGATE_REPO_ORDER"

# Get cached repo order if it matches the given root_list
# Returns hashtable with repo_order and repo_urls, or $null if no valid cache
function get-cached-repo-order {
    param(
        [Parameter(Mandatory=$true)][string[]] $root_list
    )

    $cached_json = $env:PROPAGATE_REPO_ORDER
    if (-not $cached_json) {
        return $null
    }

    try {
        $cached_data = $cached_json | ConvertFrom-Json

        # Check if this is the old format (array or missing fields)
        if ($cached_data -is [System.Array]) {
            Write-Host "Cache is old format (array), clearing cache" -ForegroundColor Yellow
            clear-cached-repo-order
            return $null
        }

        # Verify cache has required fields
        if (-not $cached_data.root_list -or -not $cached_data.repo_order) {
            Write-Host "Cache format invalid (missing fields), clearing cache" -ForegroundColor Yellow
            clear-cached-repo-order
            return $null
        }

        # Check for repo_urls (required for cloning)
        if (-not $cached_data.repo_urls) {
            Write-Host "Cache missing repo_urls, clearing cache" -ForegroundColor Yellow
            clear-cached-repo-order
            return $null
        }

        # Compare root_list - sort both for comparison
        $cached_roots = $cached_data.root_list | Sort-Object
        $current_roots = $root_list | Sort-Object

        if ($cached_roots.Count -ne $current_roots.Count) {
            Write-Host "Cache root_list count mismatch ($($cached_roots.Count) vs $($current_roots.Count)), ignoring cache" -ForegroundColor Yellow
            return $null
        }

        for ($i = 0; $i -lt $cached_roots.Count; $i++) {
            if ($cached_roots[$i] -ne $current_roots[$i]) {
                Write-Host "Cache root_list mismatch, ignoring cache" -ForegroundColor Yellow
                return $null
            }
        }

        Write-Host "Using cached repo order (root_list matches)" -ForegroundColor Cyan
        return @{
            repo_order = $cached_data.repo_order
            repo_urls = $cached_data.repo_urls
        }
    }
    catch {
        Write-Host "Failed to parse cache: $_" -ForegroundColor Yellow
        return $null
    }
}

# Save repo order to cache with the root_list and repo URLs
function set-cached-repo-order {
    param(
        [Parameter(Mandatory=$true)][string[]] $root_list,
        [Parameter(Mandatory=$true)][array] $repo_order,
        [Parameter(Mandatory=$true)] $repo_urls
    )

    $cache_data = @{
        root_list = $root_list
        repo_order = $repo_order
        repo_urls = $repo_urls
    }

    $cache_json = $cache_data | ConvertTo-Json -Compress -Depth 3
    $env:PROPAGATE_REPO_ORDER = $cache_json
    [Environment]::SetEnvironmentVariable($script:CACHE_ENV_VAR, $cache_json, "User")
    Write-Host "Repo order cached in $script:CACHE_ENV_VAR env variable" -ForegroundColor Green
}

# Clear the cached repo order
function clear-cached-repo-order {
    $env:PROPAGATE_REPO_ORDER = $null
    [Environment]::SetEnvironmentVariable($script:CACHE_ENV_VAR, $null, "User")
    Write-Host "Repo order cache cleared" -ForegroundColor Yellow
}
