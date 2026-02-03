---
name: extractLearnings
description: Extract engineering learnings from PR feedback and conversation history, then save to the appropriate skill file (or create a new skill). Use when a PR review cycle is complete or when the user wants to capture team style/preferences/practices.
argument-hint: Optional PR URL, "conversation", or add "background" to run async
---

Extract learnings about team style, preferences, and engineering practices from PR review comments and terminal prompts, then save them to the appropriate skill file or create a new skill.

## Key Principle: Skills Over CLAUDE.md

**NEVER add learnings directly to CLAUDE.md.** CLAUDE.md is reserved for cross-cutting, always-needed content (environment setup, workflow basics, shell quirks). All domain-specific learnings belong in skill files.

### Where to Save Learnings

For each learning, follow this decision tree:

1. **Find the relevant skill**: List all skills under `~/.claude/skills/` and read their SKILL.md files. Match the learning to the most relevant skill by topic.

2. **Check if the skill already has it**: Read the skill's SKILL.md and check if the learning is already documented. If yes, skip.

3. **Add to the existing skill**: If the skill exists but doesn't have the learning, use the `Edit` tool to add the learning to the appropriate section of that skill's SKILL.md.

4. **Create a new skill**: If no existing skill is relevant, create a new skill directory under `~/.claude/skills/<skill-name>/SKILL.md` with proper frontmatter (name, description, autoContext globs).

## Execution Modes

### Mode Detection
Check the arguments for execution mode:
- **Inline mode** (default): Arguments contain only a PR URL or "conversation"
- **Background mode**: Arguments contain "background", "async", or "bg"

### Background/Async Mode

If the user requests background execution (e.g., `/extractLearnings background <PR_URL>`):

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
   - Check for duplicates against existing skills
   - Write proposed learnings to: `~/.claude/pending_learnings/<PR_ID>_learnings.md`

3. **Notify the user**:
   - "Learning extraction started in background for PR #<ID>"
   - "Results will be saved to: `<output_file>`"
   - "Run `/extractLearnings approve <PR_ID>` to review and apply"

4. **User can continue working** and later:
   - Check the output file manually
   - Run `/extractLearnings approve <PR_ID>` to review and apply learnings
   - Run `/extractLearnings status` to check background agent progress

### Background Agent Prompt Template

When spawning the background agent, use this prompt:

```
Extract learnings from PR: <PR_URL>

## Instructions
1. Fetch all PR threads (use mcp__azure-devops__repo_list_pull_request_threads or parse_github_pr_comments.ps1)
2. If response is too large, use parse_pr_threads.ps1 script
3. List all skills under ~/.claude/skills/ and read their SKILL.md files
4. For each learning, find the relevant skill and check if it already documents the pattern
5. Identify NEW learnings (not already documented in any skill)
6. For each learning, create markdown with:
   - Thread ID/source
   - Category
   - Priority (High/Medium/Low)
   - Proposed text (with code examples)
   - Target skill file to update (or "NEW SKILL: <name>" if no existing skill fits)

## Output
Write results to: ~/.claude/pending_learnings/<PR_ID>_learnings.md

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
- **Target**: Update skill `<skill-name>` (or "Create new skill `<skill-name>`")

**Proposed text:**
```markdown
<exact markdown to add>
```

### Learning 2: ...
(repeat for each learning)

## Already Documented (Skipped)
- <pattern>: Already in skill `<skill-name>`
- ...
```

### Approval Workflow

When user runs `/extractLearnings approve <PR_ID>`:
1. Read `~/.claude/pending_learnings/<PR_ID>_learnings.md`
2. Present the proposed learnings to user
3. Ask for confirmation
4. Apply approved learnings to the target skill files (or create new skills)
5. Delete the pending file after successful application

---

## Inline Mode Workflow (Default)

When running inline (no "background" in arguments), follow this workflow:

### Step 1: Identify Learning Sources

Determine what sources to analyze:

1. **PR Feedback** (if PR URL provided or active PR exists):
   - Fetch all comment threads from the PR
   - Focus on reviewer comments that indicate style preferences, corrections, or best practices
   - Look for patterns in feedback across multiple comments

2. **Conversation History** (always available):
   - Review the current conversation for corrections made by the user
   - Identify repeated instructions or preferences
   - Note any explicit statements about team practices

### Step 2: Fetch PR Comments (if applicable)

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

### Step 2b: Handle Large Azure DevOps API Responses

When Azure DevOps PR threads are too large (>25K tokens), the API response cannot be read directly:

1. **Save response to file**: Let the API response save to tool-results folder (Claude Code does this automatically when response is too large)
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

### Step 2c: Extract Learnings from Conversation History

Conversation history may contain learnings from user corrections and instructions, even from earlier in the session that was compacted/summarized.

#### Accessing Full Conversation Transcript

The **full conversation transcript** is preserved even after compaction at:
```
~/.claude/projects/<project-id>/<conversation-id>.jsonl
```

The conversation ID appears in the compaction summary message:
> "If you need specific details from before compaction... read the full transcript at: `<path>.jsonl`"

#### Using the Parsing Script

1. **Use the pre-built script** at `.github/scripts/parse_conversation.ps1`
2. **Run**: `pwsh -File .github/scripts/parse_conversation.ps1 -jsonlFile "<path-to-jsonl>"`
3. **Optional**: Add `-ShowAll` to see all user messages, not just potential learnings

The script automatically identifies correction patterns:
- "No, you should..."
- "That's wrong/incorrect..."
- "Always/Never do..."
- "We prefer..."
- "HAE" / "Here and everywhere"

#### Correction Patterns to Look For

| Pattern | Example | Learning Type |
|---------|---------|---------------|
| Direct correction | "No, use X instead of Y" | Strong - explicit rule |
| Repeated instruction | Same thing said 2+ times | Strong - user emphasis |
| Explicit rule | "Always/Never do X" | Strong - clear directive |
| Preference statement | "We prefer...", "Team uses..." | Medium - team convention |
| Explanation | "The reason we do X is..." | Medium - context for rule |
| Example provision | User provides correct code | Strong - template to follow |

#### When to Use Conversation History

- **After long sessions**: Compaction may have summarized early corrections
- **When user says "remember"**: Indicates earlier instruction was given
- **When user expresses frustration**: May indicate repeated correction
- **At session end**: Review full session for patterns

### Step 3: Categorize Learnings

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

### Step 4: Identify Specific Patterns

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

### Step 5: Formulate Learning Statements

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

### Step 6: Check Existing Skills for Duplicates

Before adding learnings, check if they already exist:

1. **Scan all skill files**:
   - List all directories under `~/.claude/skills/`
   - Read each skill's `SKILL.md` file
   - Check if the learning is already documented in any skill
   - Note which skill is the best target for each new learning

2. **Check CLAUDE.md** (cross-cutting content only):
   - Location: `~/.claude/CLAUDE.md`
   - Only contains environment setup, workflow basics, shell quirks
   - Do NOT add domain-specific learnings here

3. **Project instruction files** (extract from project CLAUDE.md):
   - Read the project's `CLAUDE.md` file in the repository root
   - Extract all `@`-referenced instruction files
   - These files are already loaded into context - search them for existing documentation of the pattern

4. **Duplicate Detection Rules**:
   - If a learning is already documented in any skill or `@`-referenced instruction file, **skip it**
   - Only add learnings that are:
     - User/team-specific preferences not in standard docs
     - Project-specific conventions not covered by dependencies
     - Workflow preferences unique to this user's environment
     - Corrections to or clarifications of standard patterns

5. **When to update copilot-instructions.md instead**:
   - If a learning should apply to all developers on the project, suggest adding it to the project's `.github/copilot-instructions.md`
   - If a learning is about a dependency's patterns, note that it may belong in that dependency's instructions

### Step 7: Present Proposed Changes

Before modifying any files, present to the user:

#### Grouping Related Learnings by Target Skill

Before presenting, group related learnings by their target skill file:
- Lock-related patterns -> relevant lock/threading skill
- Test-related patterns -> test patterns skill
- Logging patterns -> logging skill
- Style patterns -> code conventions skill
- New topic with no existing skill -> propose a new skill name

#### Summary Format

1. **Summary of learnings found**:
   - List each learning with its source (PR comment ID or conversation context)
   - Indicate which are new vs already documented

2. **Proposed additions**:
   - Show the exact text to be added
   - Indicate which skill's SKILL.md it will be added to (or "New skill: `<name>`")

3. **Wait for user approval** before making changes

### Step 8: Update Skill Files

After approval:
1. **Existing skills**: Use the `Edit` tool to add new sections to the target skill's SKILL.md
2. **New skills**: Create `~/.claude/skills/<skill-name>/SKILL.md` with proper frontmatter:
   ```yaml
   ---
   name: <skill-name>
   description: <what it covers and when to use it>
   autoContext:
     - glob: "<relevant file pattern>"
   ---
   ```
3. Follow the existing format of the target skill file
4. Use code examples with CORRECT/WRONG patterns where applicable
5. **Never add to CLAUDE.md** -- all learnings go into skill files

### Step 9: Summarize Changes

Use this summary template to report changes:

| Category | Found | New | Skipped (dup) |
|----------|-------|-----|---------------|
| Code Style | X | Y | Z |
| Error Handling | X | Y | Z |
| Testing | X | Y | Z |
| Memory Management | X | Y | Z |

**Added to skills:** [numbered list with target skill name and source thread/comment IDs]

**New skills created:** [list of new skill names, if any]

**Skipped (already documented):** [list with location in existing skill]

Report:
- Number of new learnings added
- Skills updated (and any new skills created)
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
- **saveSkill**: Learnings about Claude Code usage can become skills instead
- **Manual review**: User can trigger after completing any significant work

## Tool Usage Reference

| Task | Tool | Key Parameters |
|------|------|----------------|
| Fetch ADO PR threads | `mcp__azure-devops__repo_list_pull_request_threads` | `pullRequestId`, `repositoryId`, `project` |
| Parse large PR threads | `Bash` | `pwsh -File .github/scripts/parse_pr_threads.ps1 -jsonFile "<path>" -outputDir "cmake"` -> Read `cmake/pr_threads_parsed.txt` |
| Parse GitHub comments | `Bash` | `pwsh -File .github/scripts/parse_github_pr_comments.ps1 -prUrl "<url>" -outputDir "cmake"` -> Read `cmake/github_pr_comments_parsed.txt` |
| Parse conversation history | `Bash` | `pwsh -File .github/scripts/parse_conversation.ps1 -jsonlFile "<path>"` |
| List all skills | `Bash` | `ls ~/.claude/skills/` |
| Read a skill | `Read` | `file_path: ~/.claude/skills/<name>/SKILL.md` |
| Read project CLAUDE.md | `Read` | `file_path: <repo_root>/CLAUDE.md` (to find @-referenced files) |
| Search skills for duplicates | `Grep` | `pattern` (learning keywords), `path: ~/.claude/skills/` |
| Update a skill | `Edit` | `file_path: ~/.claude/skills/<name>/SKILL.md`, `old_string`, `new_string` |
| Create new skill | `Write` | `file_path: ~/.claude/skills/<name>/SKILL.md` (with frontmatter) |

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

## Conversation Analysis Tips

When analyzing the conversation history:

1. **Look for corrections**: "No, you should..." or "That's not right..."
2. **Look for repetition**: Same instruction given multiple times
3. **Look for explicit rules**: "Always do X", "Never do Y"
4. **Look for explanations**: Why something is done a certain way
5. **Look for examples**: User providing correct code/commands as templates
6. **Look for "HAE" comments**: "HAE" means "Here And Everywhere" - indicates a pattern that should be applied throughout the codebase, not just at the commented location. These are high-value learnings that represent team-wide conventions.
