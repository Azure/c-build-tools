---
name: extract-learnings
description: Extract engineering learnings from PR feedback and save them to general_coding_instructions.md. Use when a PR review cycle is complete or when the user wants to capture team style/preferences/practices.
argument-hint: PR URL
---

Extract learnings about team style, preferences, and engineering practices from PR review comments, then save them to the project's `general_coding_instructions.md` file.

## Target File: general_coding_instructions.md

All learnings extracted from PR feedback should be saved to `general_coding_instructions.md`. This file contains team-wide coding conventions, style preferences, and best practices.

**File location:**
- In c-build-tools repo: `.github/general_coding_instructions.md`
- In higher-level repos: `deps/c-build-tools/.github/general_coding_instructions.md`

### Before Adding Learnings

1. **Read the current file**: Read `.github/general_coding_instructions.md` to understand its structure and existing content.

2. **Check for duplicates**: Ensure the learning is not already documented. If it exists, skip it.

3. **Find the right section**: Match the learning to an existing section (e.g., Code Style, Error Handling, Testing) or add a new section if needed.

4. **Add the learning**: Add the learning to the appropriate section.

## Workflow

### Step 1: Fetch PR Comments

Fetch all comment threads from the PR:
- Focus on reviewer comments that indicate style preferences, corrections, or best practices
- Look for patterns in feedback across multiple comments

#### For Azure DevOps PRs
```
URL pattern: https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
```
1. Use `mcp__azure-devops__repo_list_repos_by_project` to get repository ID
2. Use `mcp__azure-devops__repo_list_pull_request_threads` to fetch all threads
3. For each thread, use `mcp__azure-devops__repo_list_pull_request_thread_comments` if needed

#### For GitHub PRs
```
URL pattern: https://github.com/{owner}/{repo}/pull/{number}
```
**Use the pre-built parsing script** that fetches and filters comments directly.

**IMPORTANT**: Use `-ShowResolved YES` to include ALL comments (resolved and unresolved) for extracting learnings:
```bash
pwsh -File .github/scripts/parse_github_pr_comments.ps1 -prUrl "https://github.com/owner/repo/pull/123" -outputDir "cmake" -ShowResolved YES
```

Then read the output: `Read cmake/extract-learnings/github_pr_comments_parsed.txt`

The script automatically:
- Fetches comments via `gh api` (requires GitHub CLI authenticated)
- With `-ShowResolved YES`: Shows ALL comments for learning extraction
- With `-ShowResolved NO`: Only shows active/unresolved comments
- Groups comments by file for easier reading
- Shows active comment count vs resolved count
- Writes output to `cmake/extract-learnings/github_pr_comments_parsed.txt` for easy access

### Step 1b: Handle Large Azure DevOps API Responses

When Azure DevOps PR threads are too large (>25K tokens), the API response cannot be read directly:

1. **Save response to file**: Let the API response save to tool-results folder (this happens automatically when response is too large)
2. **Use the pre-built parsing script** at `.github/scripts/parse_pr_threads.ps1`
3. **Run** with `-ShowResolved YES` to include ALL threads for learning extraction:
   ```bash
   pwsh -File .github/scripts/parse_pr_threads.ps1 -jsonFile "<path-to-tool-results>" -outputDir "cmake" -ShowResolved YES
   ```
4. **Read the output**: `Read cmake/pr_threads_parsed.txt`

The script automatically filters out:
- Bot comments (MerlinBot, Azure Pipelines)
- PR-level comments without file context
- With `-ShowResolved YES`: Includes closed/resolved threads for learning extraction
- With `-ShowResolved NO`: Only shows active threads

Output is written to `cmake/pr_threads_parsed.txt` for easy access.

#### Filtering PR Comments

**Include:**
- Comments with `threadContext` (file-specific feedback)
- Status: `active` or `pending` (not `closed`)
- Human reviewers (team members)

**Exclude:**
- Bot comments (MerlinBot, Azure Pipelines, etc.)
- PR-level comments without file context
- System-generated threads (build status, etc.)

### Step 2: Categorize Learnings

Match learnings to existing sections in `general_coding_instructions.md`:

| Section | Examples |
|---------|----------|
| **Function Naming Conventions** | Naming patterns, module prefixes, visibility rules |
| **Function Structure Guidelines** | Organization, async callbacks, complexity |
| **Variable Naming Conventions** | Variable naming patterns, special types |
| **Result Variable Conventions** | Initialization, return patterns |
| **Parameter Validation Rules** | Validation order, combined checks, logging |
| **Goto Usage Rules** | Permitted patterns, label naming |
| **Indentation and Formatting** | Spacing, brace style, alignment |
| **If/Else Formatting Rules** | Multi-condition, bracing, error chains |
| **Additional Conventions** | Mockable functions, header order, memory management, pointer casting, error handling, reference counting, async operations, requirements traceability |

If a learning doesn't fit an existing section, propose a new section.

### Step 3: Identify Specific Patterns

Look for these types of learnings in feedback:

1. **Direct Corrections**:
   - "Use X instead of Y"
   - "This should be..."
   - "Wrong pattern, correct is..."

2. **Style Preferences**:
   - "We prefer..."
   - "Team convention is..."
   - "Always/Never do..."

3. **Implicit Patterns**:
   - Repeated similar corrections across multiple comments
   - Consistent feedback about specific constructs
   - Comments indicating codebase-wide patterns (e.g., "do this everywhere", "same issue")

4. **Best Practices**:
   - Performance recommendations
   - Safety/security patterns
   - Thread-safety requirements

### Learning Prioritization

**High Priority** (always capture):
- Comments indicating team-wide conventions (e.g., "do this everywhere", "same issue")
- Thread-safety/deadlock patterns
- Memory leak prevention patterns
- Patterns repeated by multiple reviewers

**Medium Priority** (capture if generalizable):
- Style preferences with clear reasoning
- Performance recommendations
- Test patterns

### Step 4: Formulate Learning Statements

Convert raw feedback into actionable learning statements:

**From PR Comment:**
> "const can't size arrays in MSVC, use #define"

**Learning Statement:**
```markdown
#### Array Sizes: Use `#define`, Not `const`
MSVC doesn't support VLAs. Use `#define` macros for array sizes:
```c
// WRONG
const uint32_t size = 3;
TYPE items[size];  // Compiler error!

// CORRECT
#define SIZE 3
TYPE items[SIZE];
```
```

### Step 5: Check for Duplicates

Before adding learnings, check if they already exist in `.github/general_coding_instructions.md`:

1. **Read the guidelines file**:
   - Read `.github/general_coding_instructions.md`
   - Understand its structure and existing sections
   - Check if the learning is already documented

2. **Duplicate Detection Rules**:
   - If a learning is already documented, **skip it**
   - Only add learnings that are:
     - Team-specific preferences not already in the file
     - New conventions established through PR feedback
     - Corrections to or clarifications of existing patterns

### Step 6: Present Proposed Changes

Before modifying any files, present a **numbered list** of proposed learnings so the user can select which to keep:

1. **Group learnings by target section** in general_coding_instructions.md
2. **Present each learning as a numbered item**:
   ```
   1. [Function Naming] Use snake_case for all internal helpers (Source: PR comment #123)
   2. [Error Handling] Always log all parameters on validation failure (Source: PR comment #456)
   3. [Memory Management] Use malloc_2 for array allocations (Source: PR comment #789)
   ```
3. **Ask user to respond with**:
   - Specific numbers to keep (e.g., "1, 3")
   - "keep all" to apply all proposed changes
4. **Only apply the selected learnings**

### Step 7: Update general_coding_instructions.md

After approval:
1. **Read the current file**: Read `.github/general_coding_instructions.md` to get the current content
2. **Find the target section**: Locate the appropriate section for each learning
3. **Add the learning**: Use the `Edit` tool to add the learning to the appropriate section
4. **Create new sections if needed**: If no existing section fits, add a new section with a clear heading
5. Follow the existing format of the file
6. Use code examples with CORRECT/WRONG patterns where applicable

### Step 8: Summarize Changes

Use this summary template to report changes:

| Category | Found | New | Skipped (dup) |
|----------|-------|-----|---------------|
| Code Style | X | Y | Z |
| Error Handling | X | Y | Z |
| Testing | X | Y | Z |
| Memory Management | X | Y | Z |

**Added to general_coding_instructions.md:** [numbered list with section name and source thread/comment IDs]

**New sections created:** [list of new section names, if any]

**Skipped (already documented):** [list with location in existing section]

Report:
- Number of new learnings added
- Sections updated (and any new sections created)
- Categories covered

## Guidelines

### What Makes a Good Learning

- **Specific**: "Use `#define` for array sizes" not "Be careful with arrays"
- **Actionable**: Shows what TO DO and what NOT to do
- **Generalizable**: Applies beyond the specific PR/file
- **Documented with examples**: Include code snippets when relevant

### What to Skip

- One-off typos or simple mistakes
- Context-specific fixes that don't generalize
- **Already documented in copilot-instructions.md or general_coding_instructions.md**
- Patterns that are standard practice in the dependency chain
- Temporary workarounds
- Learnings that belong in project docs rather than personal memory

### Format Conventions

- Use markdown headers to organize sections
- Use code blocks with language hints (```c, ```powershell)
- Use tables for reference information
- Use CORRECT/WRONG patterns with comments
