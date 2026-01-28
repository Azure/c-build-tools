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
$repos = & "./discover-submodules.ps1" -RepoPath "<starting-repo-path>"
```

The script returns a list of objects with:
- `Name`: Repository name
- `Path`: Relative path in parent repo
- `Url`: Git remote URL
- `Commit`: Current commit SHA

### Step 3: Clone repositories to work area and create topic branch

Use the [clone script](./clone-repos.ps1) to clone all discovered repos and create the topic branch:

```powershell
# Clone the main repo and all submodules to the work area with topic branch
& "./clone-repos.ps1" -Repos $repos -WorkArea $workArea -Branch "<branch-name>"
```

This clones each repo and creates the specified topic branch. **All changes will be made on this branch.**

### Step 4: Apply changes

Apply the requested changes across the cloned repositories on the topic branch:

1. Analyze which repos need modification based on the change prompt
2. Make changes in dependency order (deepest dependencies first)
3. Ensure all changes are made on the topic branch created in Step 3

### Step 5: Build and test

For each modified repository, build and run tests to verify the changes:

```powershell
# Configure CMake
cmake -S . -B cmake -G "Visual Studio 17 2022" -A x64 -Drun_unittests=ON -Drun_int_tests=ON

# Build
cmake --build cmake --config Debug

# Run tests
ctest --test-dir cmake -C Debug --output-on-failure
```

**Fix any build or test failures before proceeding.** Iterate until:
- All unit tests pass
- All integration tests pass (if applicable)

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
git commit -m "[MrBot] <brief description of changes>

<detailed description if needed>"

# Push the topic branch to remote
git push -u origin <branch-name>
```

Commit message guidelines:
- Prefix with `[MrBot]` for automated changes
- First line: brief summary (50 chars or less)
- Body: detailed explanation if needed

### Step 9: Open draft PR

Create a draft pull request for each modified repository using the appropriate tool based on the repository host:

**For GitHub repositories** (use GitHub CLI):
```powershell
gh pr create --draft --title "[MrBot] <PR title>" --body "<PR description>"
```

**For Azure DevOps repositories** (use ADO MCP tools):
Use the `ado-repo_create_pull_request` tool with `isDraft: true`:
- `repositoryId`: The repository ID
- `sourceRefName`: The topic branch (e.g., `refs/heads/feature/my-change`)
- `targetRefName`: The target branch (e.g., `refs/heads/main`)
- `title`: PR title prefixed with `[MrBot]`
- `description`: PR description
- `isDraft`: `true`

The draft PR should:
- Reference related PRs in other repos in the hierarchy
- Link to relevant work items or issues
- Include a summary of changes made

## Example workflow

```powershell
# 1. Set up work area
$workArea = Join-Path $env:TEMP "repo-hierarchy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $workArea -Force
$branchName = "feature/my-change"

# 2. Discover submodules from starting repo
$startingRepo = "D:\w\store4"
$repos = & "$PSScriptRoot\discover-submodules.ps1" -RepoPath $startingRepo -IncludeRoot

# 3. Clone all repos with topic branch
& "$PSScriptRoot\clone-repos.ps1" -Repos $repos -WorkArea $workArea -Branch $branchName

# 4. For each repo that needs changes:
foreach ($repo in $modifiedRepos) {
    Push-Location $repo.WorkAreaPath
    
    # Apply changes based on prompt (already on topic branch)
    # ... changes applied ...
    
    # Build and test
    cmake -S . -B cmake -G "Visual Studio 17 2022" -A x64 -Drun_unittests=ON
    cmake --build cmake --config Debug
    ctest --test-dir cmake -C Debug --output-on-failure
    
    # Run traceability
    cmake --build cmake --target traceability
    
    # Run repo validation
    cmake --build cmake --target repo_validation
    
    # Commit and push
    git add -A
    git commit -m "[MrBot] Apply changes for: $branchName"
    git push -u origin $branchName
    
    # Create draft PR
    gh pr create --draft --title "[MrBot] $branchName" --body "Part of hierarchy-wide change"
    
    Pop-Location
}

# 5. Show summary
Write-Host "Work area: $workArea"
Write-Host "Repositories modified: $($modifiedRepos.Count)"
```

## Best practices

- **Always create a topic branch** before making any changes
- Always work in the temporary work area to avoid modifying original repos
- Apply changes in dependency order (leaf repos first, then parents)
- Use consistent branch names across all repos (e.g., `feature/description`)
- Create atomic commits with clear messages referencing the change
- **Never push to main/master directly** - always use PRs
- Fix all test, traceability, and validation errors before committing
- Consider using a single PR description that links all related PRs

## Cleanup

After completing the changes and pushing to remote:

```powershell
# Remove the temporary work area
Remove-Item -Recurse -Force $workArea
```
