---
name: review-pr
description: Review a pull request for functional issues, coding guideline adherence, and best practices. Use this when asked to review, inspect, or provide feedback on a pull request (Azure DevOps or GitHub). Proposes comments for user approval before posting.
---

# Review a Pull Request

This skill reviews a pull request for functional issues, adherence to coding guidelines, and best practices. It proposes comments one at a time for user approval, then posts the approved comments.

## When to Use

Use this skill when:
- You are asked to review a pull request
- You are asked to inspect or provide feedback on PR changes
- You are given a PR URL (Azure DevOps or GitHub)

## Inputs

- **PR URL**: A URL to a pull request on Azure DevOps or GitHub

## Process

### Phase 1: Fetch PR Metadata

Use the appropriate tool based on the PR platform:

- **Azure DevOps PRs**: Use ADO MCP tools
  1. Parse the PR URL to extract org, project, repo, and PR ID
  2. Use `ado-repo_get_repo_by_name_or_id` to get the repository ID
  3. Use `ado-repo_get_pull_request_by_id` to get PR details (title, description, branches)
  4. Use `ado-repo_list_pull_request_threads` to get existing comment threads
- **GitHub PRs**: Use GitHub MCP tools
  1. Use `github-mcp-server-pull_request_read` with method `get` for PR details
  2. Use `github-mcp-server-pull_request_read` with method `get_review_comments` for existing comments

### Phase 2: Fetch and Analyze the Diff

1. **Fetch the PR branch** locally using `git fetch`
2. **Get the diff stats** to understand the scope of changes:
   ```
   git --no-pager diff --stat origin/<target>...<source-branch>
   ```
3. **Get the full diff** for each changed file:
   ```
   git --no-pager diff origin/<target>...<source-branch> -- <file-path>
   ```
4. If the diff is large, save to temp files and review in sections using `view` with `view_range`

### Phase 3: Analyze the Codebase for Context

To provide meaningful review, understand the broader context:

1. **Read coding guidelines**: Check `deps/c-build-tools/.github/general_coding_instructions.md` and the relevant `copilot-instructions.md` files for coding standards
2. **Check existing patterns**: Search the codebase for similar patterns to verify consistency:
   - Use `grep` to find related functions, macros, or patterns
   - Check if all instances of a repeated pattern were updated (e.g., all callback handlers, all enum values)
3. **Cross-reference documentation**: If requirements docs are changed, verify they match the code changes
4. **Check for completeness**: If a change is applied to multiple similar locations, verify none were missed

### Phase 4: Identify Review Issues

Look for these categories of issues:

#### Functional Issues (High Priority)
- Missing updates in similar/repeated patterns (e.g., handler not updated)
- Logic errors or incorrect conditions
- Thread-safety issues (missing atomics, race conditions)
- Resource leaks (memory, handles, references)
- Missing error handling paths
- Incorrect enum values or constant usage

#### Coding Guideline Adherence
- Code must adhere to the rules in `general_coding_instructions.md` — refer to that file for the authoritative set of conventions rather than duplicating specific rules here

### Phase 5: Propose Comments for Approval

Present each proposed comment to the user **one at a time** using the `ask_user` tool:

1. Show the comment text including:
   - The file and location
   - The issue description
   - Why it matters (functional bug, consistency, convention)
2. Ask the user to **Approve**, **Skip**, or **Modify** each comment
3. Track the status of each comment (use a SQL table or in-memory tracking)

**Key Principle**: Never post comments without explicit user approval.

### Phase 6: Post Approved Comments

After all comments have been reviewed by the user, post the approved ones:

- **Azure DevOps PRs**: Use `ado-repo_create_pull_request_thread` for each comment
  - Set `filePath` to the target file
  - Set `rightFileStartLine` / `rightFileEndLine` for inline comments
  - Use `status: "Active"` (default)
- **GitHub PRs**: Use GitHub MCP tools or CLI to create review comments

### Phase 7: Cleanup

1. Remove any temporary diff files created during analysis
2. Summarize the results:
   - Number of comments proposed
   - Number approved and posted
   - Number skipped

## Comment Format

All posted comments **must** be prefixed with `[MrBot]` to clearly identify AI-generated feedback:

```
[MrBot] The `on_foo_complete` handler is missing the `SET_FLAG` macro call.
All other handlers were updated — this one appears to have been accidentally skipped.
```

## Guidelines

### What Makes a Good Review Comment

- **Specific**: Point to the exact code location and describe the issue precisely
- **Actionable**: Clearly state what should be changed
- **Justified**: Explain why the change is needed (bug, convention, consistency)
- **Non-trivial**: Focus on issues that genuinely matter — bugs, correctness, completeness
- **Respectful**: Use constructive language

### What to Avoid

- **Style-only nits**: Don't comment on formatting preferences unless they violate documented conventions
- **Redundant comments**: Don't repeat the same issue on every occurrence — mention it once and note it applies elsewhere
- **Obvious observations**: Don't restate what the code already clearly does
- **Speculative concerns**: Only flag issues you can substantiate with evidence from the codebase or guidelines

### Prioritization

Focus review effort on:
1. **Completeness gaps**: Changes that were applied to most but not all similar locations
2. **Functional correctness**: Logic that doesn't match the stated requirements
3. **Adherence to coding guidelines**: Violations of conventions in `general_coding_instructions.md`
4. **Documentation-code mismatch**: Requirements docs that don't match the implementation

## Example Workflow

Given PR URL: `https://msazure.visualstudio.com/One/_git/MyRepo/pullrequest/12345`

1. Parse URL → org: `msazure`, project: `One`, repo: `MyRepo`, PR: `12345`
2. Fetch repo ID via `ado-repo_get_repo_by_name_or_id`
3. Fetch PR details and existing threads
4. Fetch the source branch: `git fetch origin feature/my-change`
5. Get diff: `git --no-pager diff origin/master...feature/my-change`
6. Read coding guidelines from `deps/c-build-tools/.github/general_coding_instructions.md`
7. Search codebase for related patterns to verify completeness
8. Identify issues (e.g., 3 handlers missed, 1 doc mismatch)
9. Present each comment to user for approval
10. Post approved comments with `[MrBot]` prefix
11. Clean up temp files and summarize results
