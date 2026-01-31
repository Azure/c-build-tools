---
name: apply-change-to-repo-hierarchy
description: Apply changes across a repository and all its git submodules. Use this skill when asked to make changes that need to propagate through a repository hierarchy, modify multiple dependent repos at once, or apply consistent changes across a codebase with submodules.
---

# Repository Hierarchy Change

This skill helps apply changes across a repository and all its git submodules in a coordinated way.

## When to use this skill

Use this skill when you need to:
- Apply consistent changes across a repo and its submodules
- Refactor code that spans multiple dependent repositories
- Update configuration, headers, or patterns across an entire dependency tree
- Make breaking changes that require coordinated updates

**Note**: This skill differs from traditional scripts like `repo_work.ps1` because it applies AI-driven, context-aware changes to each repository based on a prompt, rather than running a fixed script across all repos.

## Inputs

1. **Repository path**: The starting repository (can be a local path or URL)
2. **Change prompt**: Description of changes to apply across the hierarchy
3. **Branch name**: Topic branch name for the changes (e.g., `feature/my-change`)

## Process

### Step 1: Set up temporary work area

Create a temporary work area for the operation:

```powershell
$workArea = Join-Path $env:TEMP "repo-hierarchy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $workArea -Force
```

### Step 2: Discover all submodules

Use the [submodule discovery script](./discover-submodules.ps1) to enumerate all repositories in the hierarchy:

```powershell
# From the starting repository, discover all submodules recursively
$repos = & "./discover-submodules.ps1" -RepoPath "<starting-repo-path>" -IncludeRoot
```

The script returns a list of objects ordered from deepest dependencies first (leaf repos) to root, with:
- `Name`: Repository name
- `Url`: Git remote URL
- `AbsolutePath`: Local path to the repository

The script automatically:
- Deduplicates repos (each unique repo appears once)
- Excludes third-party repos (libuv, mimalloc, jemalloc, vcpkg by default)
- Orders repos by dependency depth (deepest first)

**Note**: This script uses similar logic to `update_deps/build_graph.ps1` for computing dependency order.

### Step 3: Clone repositories to work area and create topic branch

Use the [clone script](./clone-repos.ps1) to clone all discovered repos and create the topic branch:

```powershell
# Clone the main repo and all submodules to the work area with topic branch
& "./clone-repos.ps1" -Repos $repos -WorkArea $workArea -Branch "<branch-name>"
```

This clones each repo and creates the specified topic branch. **All changes will be made on this branch.**

### Step 4: Apply changes (leaf to root)

Apply the requested changes across the cloned repositories **in dependency order** (deepest dependencies first):

1. The repos are already ordered correctly from Step 2 (leaf repos first)
2. For each repo, starting with the deepest dependencies:
   - Update submodule references to latest master before applying changes
   - Apply changes based on the change prompt
   - Ensure all changes are made on the topic branch created in Step 3

**Important**: Processing in this order ensures that when you modify a parent repo, its submodule dependencies have already been updated and merged.

### Step 5: Build and test

For each modified repository, build and run tests to verify the changes:

```powershell
# Configure CMake (with VLD enabled, LTCG disabled for faster builds)
cmake -S . -B cmake -G "Visual Studio 17 2022" -A x64 `
    -Drun_unittests=ON `
    -Drun_int_tests=ON `
    -Duse_vld=ON `
    -Duse_ltcg=OFF

# Build
cmake --build cmake --config Debug

# Run tests (use -j for parallel execution of unit tests)
ctest --test-dir cmake -C Debug --output-on-failure -j 8
```

**Fix any build or test failures before proceeding.** Iterate until:
- All unit tests pass
- All integration tests pass (if applicable)

**Note**: If integration tests take too long, you can skip them initially with `-Drun_int_tests=OFF` and run them separately or rely on CI.

### Step 6: Run traceability

Run the traceability target to ensure all requirements are properly traced:

```powershell
# Run traceability check
cmake --build cmake --target traceability
```

**Fix any traceability errors before proceeding.** Common issues:
- Missing requirement tags in code
- Unlinked requirements in documentation
- Orphaned test cases

### Step 7: Run repo validation

Run repository validation to ensure code quality and standards compliance:

```powershell
# Run repo validation
cmake --build cmake --target repo_validation
```

**Fix any validation errors before proceeding.** This checks:
- Code formatting and style
- Header inclusion order
- License headers
- Other repository-specific rules

### Step 8: Commit and push

After all validations pass, commit and push the changes:

```powershell
# Stage all changes
git add -A

# Commit with descriptive message
git commit -m "[MrBot] <brief description of changes>"

# Push the topic branch to remote
git push -u origin <branch-name>
```

Commit message guidelines:
- Prefix with `[MrBot]` for automated changes
- First line: brief summary (50 chars or less)
- Keep it concise - avoid multi-line commit messages

### Step 9: Open PR and wait for merge

**Important**: Because submodule SHAs must exist in the target branch before parent repos can reference them, you must process repos sequentially: push → open PR → wait for merge → proceed to next repo.

Create a pull request for each modified repository:

**For GitHub repositories** (use GitHub CLI):
```powershell
gh pr create --title "[MrBot] <PR title>" --body "<PR description>"
```

**For Azure DevOps repositories** (use ADO MCP tools):
Use the `ado-repo_create_pull_request` tool:
- `repositoryId`: The repository ID
- `sourceRefName`: The topic branch (e.g., `refs/heads/feature/my-change`)
- `targetRefName`: The target branch (e.g., `refs/heads/main`)
- `title`: PR title prefixed with `[MrBot]`
- `description`: PR description

**Wait for the PR to be reviewed and merged before proceeding to the next repository in the hierarchy.** This ensures that when parent repos update their submodule references, the new commits exist in the submodule's main branch.

## Example workflow

```powershell
# 1. Set up work area
$workArea = Join-Path $env:TEMP "repo-hierarchy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $workArea -Force
$branchName = "feature/my-change"

# 2. Discover submodules from starting repo (ordered deepest-first)
$startingRepo = "D:\w\store4"
$repos = & "$PSScriptRoot\discover-submodules.ps1" -RepoPath $startingRepo -IncludeRoot

# 3. Clone all repos with topic branch
$clonedRepos = & "$PSScriptRoot\clone-repos.ps1" -Repos $repos -WorkArea $workArea -Branch $branchName

# 4. Process each repo in order (deepest dependencies first)
foreach ($repo in $clonedRepos) {
    Push-Location $repo.WorkAreaPath
    
    # Update submodules to latest master
    git submodule update --remote --merge
    
    # Apply changes based on prompt (already on topic branch)
    # ... changes applied by AI based on context ...
    
    # Build and test
    cmake -S . -B cmake -G "Visual Studio 17 2022" -A x64 `
        -Drun_unittests=ON -Duse_vld=ON -Duse_ltcg=OFF
    cmake --build cmake --config Debug
    ctest --test-dir cmake -C Debug --output-on-failure -j 8
    
    # Run traceability
    cmake --build cmake --target traceability
    
    # Run repo validation
    cmake --build cmake --target repo_validation
    
    # Commit and push
    git add -A
    git commit -m "[MrBot] Apply changes for: $branchName"
    git push -u origin $branchName
    
    # Create PR and wait for merge before proceeding
    gh pr create --title "[MrBot] $branchName" --body "Part of hierarchy-wide change"
    # Wait for PR to be merged...
    
    Pop-Location
}

# 5. Show summary
Write-Host "Work area: $workArea"
Write-Host "Repositories processed: $($clonedRepos.Count)"
```

## Best practices

- **Always create a topic branch** before making any changes
- Always work in the temporary work area to avoid modifying original repos
- **Process repos in dependency order** (leaf repos first, then parents)
- Use consistent branch names across all repos (e.g., `feature/description`)
- Create atomic commits with clear messages referencing the change
- **Never push to main/master directly** - always use PRs
- Fix all test, traceability, and validation errors before committing
- **Wait for each PR to merge** before processing parent repos (submodule SHAs must exist)

## Cleanup

After completing the changes and pushing to remote:

```powershell
# Remove the temporary work area
Remove-Item -Recurse -Force $workArea
```
