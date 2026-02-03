---
name: extract-learnings
description: Extract engineering learnings from PR feedback and save them to general_coding_guidelines.md. Use when a PR review cycle is complete or when the user wants to capture team style/preferences/practices.
argument-hint: Optional PR URL, or add "background" to run async
---

Extract learnings about team style, preferences, and engineering practices from PR review comments, then save them to the project's `general_coding_guidelines.md` file.

## Target File: general_coding_guidelines.md

All learnings extracted from PR feedback should be saved to the project's `.github/general_coding_guidelines.md` file. This file contains team-wide coding conventions, style preferences, and best practices.

### Before Adding Learnings

1. **Read the current file**: Read `.github/general_coding_guidelines.md` to understand its structure and existing content.

2. **Check for duplicates**: Ensure the learning is not already documented. If it exists, skip it.

3. **Find the right section**: Match the learning to an existing section (e.g., Code Style, Error Handling, Testing) or add a new section if needed.

4. **Add the learning**: Use the `Edit` tool to add the learning to the appropriate section.

## Execution Modes

### Mode Detection
Check the arguments for execution mode:
- **Inline mode** (default): Arguments contain only a PR URL
- **Background mode**: Arguments contain "background", "async", or "bg"

### Background/Async Mode

If the user requests background execution (e.g., `/extract-learnings background <PR_URL>`):

1. **Spawn a background agent** using the Task tool:
   ```
   Task tool with:
   - subagent_type: "general-purpose"
   - run_in_background: true
   - prompt: Contains the full extraction workflow below
   ```

2. **The background agent will**:
   - Fetch and parse PR threads
   - Analyze learnings
   - Check for duplicates against `.github/general_coding_guidelines.md`
   - Write proposed learnings to: `pending_learnings/<PR_ID>_learnings.md`

3. **Notify the user**:
   - "Learning extraction started in background for PR #<ID>"
   - "Results will be saved to: `<output_file>`"
   - "Run `/extract-learnings approve <PR_ID>` to review and apply"

4. **User can continue working** and later:
   - Check the output file manually
   - Run `/extract-learnings approve <PR_ID>` to review and apply learnings
   - Run `/extract-learnings status` to check background agent progress

### Background Agent Prompt Template

When spawning the background agent, use this prompt:

```
Extract learnings from PR: <PR_URL>

## Instructions
1. Fetch all PR threads (use mcp__azure-devops__repo_list_pull_request_threads or parse_github_pr_comments.ps1)
2. If response is too large, use parse_pr_threads.ps1 script
3. Read `.github/general_coding_guidelines.md` to understand existing content
4. For each learning, check if it already exists in general_coding_guidelines.md
5. Identify NEW learnings (not already documented)
6. For each learning, create markdown with:
   - Thread ID/source
   - Category
   - Priority (High/Medium/Low)
   - Proposed text (with code examples)
   - Target section in general_coding_guidelines.md

## Output
Write results to: pending_learnings/<PR_ID>_learnings.md

Format:
# Proposed Learnings from PR #<ID>

## Summary
- Total threads analyzed: X
- Learnings found: Y
- Already documented (skip): Z
- New learnings to add: W

## New Learnings

### Learning 1: <Title>
- **Source**: Thread <ID>
- **Category**: <category>
- **Priority**: <High/Medium/Low>
- **Target section**: <section name in general_coding_guidelines.md>

**Proposed text:**
```markdown
<exact markdown to add>
```

### Learning 2: ...
(repeat for each learning)

## Already Documented (Skipped)
- <pattern>: Already in general_coding_guidelines.md
- ...
```

### Approval Workflow

When user runs `/extract-learnings approve <PR_ID>`:
1. Read `pending_learnings/<PR_ID>_learnings.md`
2. Present the proposed learnings to user
3. Ask for confirmation
4. Apply approved learnings to `.github/general_coding_guidelines.md`
5. Delete the pending file after successful application

---

## Inline Mode Workflow (Default)

When running inline (no "background" in arguments), follow this workflow:

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

Then read the output: `Read cmake/github_pr_comments_parsed.txt`

The script automatically:
- Fetches comments via `gh api` (requires GitHub CLI authenticated)
- With `-ShowResolved YES`: Shows ALL comments for learning extraction
- With `-ShowResolved NO`: Only shows active/unresolved comments
- Groups comments by file for easier reading
- Shows active comment count vs resolved count
- Writes output to `cmake/github_pr_comments_parsed.txt` for easy access

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
- Closed/resolved threads (already addressed)
- PR-level comments without file context
- System-generated threads (build status, etc.)

### Step 2: Categorize Learnings

Extract and categorize learnings into these categories:

| Category | Examples |
|----------|----------|
| **Code Style** | Naming conventions, brace placement, comment style |
| **Error Handling** | Patterns for error paths, cleanup order, goto usage |
| **Testing Practices** | Test structure, mocking patterns, cleanup requirements |
| **Memory Management** | THANDLE patterns, leak prevention, allocation rules |
| **Documentation** | Comment requirements, SRS tagging, test documentation |
| **Build/CI** | Build commands, test execution, validation targets |
| **Git Workflow** | Commit message style, branch naming, PR practices |
| **Platform Specifics** | Windows vs Linux patterns, cross-platform considerations |

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
   - HAE ("Here And Everywhere") comments indicating codebase-wide patterns

4. **Best Practices**:
   - Performance recommendations
   - Safety/security patterns
   - Thread-safety requirements

### Learning Prioritization

**High Priority** (always capture):
- HAE ("Here And Everywhere") comments - team-wide conventions
- Thread-safety/deadlock patterns
- Memory leak prevention patterns
- Patterns repeated by multiple reviewers

**Medium Priority** (capture if generalizable):
- Style preferences with clear reasoning
- Performance recommendations
- Test patterns

**Low Priority** (consider skipping):
- One-off fixes for specific code
- Subjective preferences without team consensus

### Reviewer Context

Note the reviewer's role when weighing feedback:
- **Senior team members**: High authority, likely represent team standards
- **Code owners**: Domain experts for their area
- **Bots (MerlinBot)**: Automated suggestions, useful but lower priority than human reviewers

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

Before adding learnings, check if they already exist in `.github/general_coding_guidelines.md`:

1. **Read the guidelines file**:
   - Read `.github/general_coding_guidelines.md`
   - Understand its structure and existing sections
   - Check if the learning is already documented

2. **Duplicate Detection Rules**:
   - If a learning is already documented, **skip it**
   - Only add learnings that are:
     - Team-specific preferences not already in the file
     - New conventions established through PR feedback
     - Corrections to or clarifications of existing patterns

### Step 6: Present Proposed Changes

Before modifying any files, present to the user:

#### Grouping Related Learnings by Section

Before presenting, group related learnings by their target section in general_coding_guidelines.md:
- Lock-related patterns -> Threading/Concurrency section
- Test-related patterns -> Testing section
- Logging patterns -> Logging section
- Style patterns -> Code Style section
- New topic -> propose a new section name

#### Summary Format

1. **Summary of learnings found**:
   - List each learning with its source (PR comment ID)
   - Indicate which are new vs already documented

2. **Proposed additions**:
   - Show the exact text to be added
   - Indicate which section of general_coding_guidelines.md it will be added to

3. **Wait for user approval** before making changes

### Step 7: Update general_coding_guidelines.md

After approval:
1. **Read the current file**: Read `.github/general_coding_guidelines.md` to get the current content
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

**Added to general_coding_guidelines.md:** [numbered list with section name and source thread/comment IDs]

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

### Integration Points

The skill integrates with existing workflows:
- **addressPrReviewComments**: After addressing PR comments, run this to capture learnings
- **Manual review**: User can trigger after completing any significant work

## Tool Usage Reference

| Task | Tool | Key Parameters |
|------|------|----------------|
| Fetch ADO PR threads | `mcp__azure-devops__repo_list_pull_request_threads` | `pullRequestId`, `repositoryId`, `project` |
| Parse large PR threads | `Bash` | `pwsh -File .github/scripts/parse_pr_threads.ps1 -jsonFile "<path>" -outputDir "cmake"` -> Read `cmake/pr_threads_parsed.txt` |
| Parse GitHub comments | `Bash` | `pwsh -File .github/scripts/parse_github_pr_comments.ps1 -prUrl "<url>" -outputDir "cmake"` -> Read `cmake/github_pr_comments_parsed.txt` |
| Read guidelines | `Read` | `file_path: .github/general_coding_guidelines.md` |
| Search for duplicates | `Grep` | `pattern` (learning keywords), `path: .github/general_coding_guidelines.md` |
| Update guidelines | `Edit` | `file_path: .github/general_coding_guidelines.md`, `old_string`, `new_string` |

## Example Extraction

### PR Comment:
```
Thread on src/module.c line 125:
"Helgrind stack address reuse - use heap-allocated callback contexts"
```

### Extracted Learning:
```markdown
### Avoiding Global State Issues
- **Use heap-allocated callback contexts**: Avoids stack address reuse issues in multi-threaded tests
- **All callbacks must complete**: Ensure all callbacks from a test are awaited before the next test starts

Pattern for heap-allocated contexts:
```c
// Create helper
CONTEXT* context_create(void) {
    CONTEXT* ctx = malloc(sizeof(CONTEXT));
    (void)interlocked_exchange(&ctx->flag, 0);
    return ctx;
}

// Destroy helper
void context_destroy(CONTEXT* ctx) {
    free(ctx);
}

// Usage in test
CONTEXT* ctx = context_create();
// ... use ctx ...
context_destroy(ctx);
```
```

