---
name: approve-prs
description: Approve a list of pull requests on GitHub and/or Azure DevOps. Use this skill when the user provides one or more PR links and wants them approved. Triggers include "approve PRs", "approve these PRs", "approve pull requests", "vote approve".
argument-hint: Space or newline separated list of PR URLs
---

Approve the provided list of pull requests. Supports both GitHub and Azure DevOps PRs.

## Workflow

### Step 1: Parse the PR Links

Extract PR URLs from the user's input. Each URL determines the platform and approval method:

- **GitHub**: `https://github.com/{owner}/{repo}/pull/{number}`
- **Azure DevOps**: `https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}`
- **Azure DevOps (old)**: `https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}`

Create a todo list item for each PR to track progress.

### Step 2: Approve Each PR

Process each PR sequentially. For each PR:

#### GitHub PRs

Use the GitHub CLI to approve:

```bash
gh pr review {number} --repo {owner}/{repo} --approve
```

To add an approval comment:
```bash
gh pr review {number} --repo {owner}/{repo} --approve --body "Approved"
```

#### Azure DevOps PRs

Use the ADO MCP tools to approve. Follow these steps:

1. **Get the repository ID**:
   - Use `mcp__azure-devops__repo_get_repo_by_name_or_id` with `project` and `repositoryNameOrId` extracted from the URL

2. **Get the PR details**:
   - Use `mcp__azure-devops__repo_get_pull_request_by_id` with `repositoryId` and `pullRequestId` to verify the PR exists and is active

3. **Get the current user's identity ID**:
   - Use `mcp__azure-devops__core_get_identity_ids` with the user's email as `searchFilter`
   - If the user's email is not known, ask them

4. **Add the user as a reviewer (if not already)**:
   - Use `mcp__azure-devops__repo_update_pull_request_reviewers` with `repositoryId`, `pullRequestId`, `reviewerIds` (the identity ID from step 3), and `action: "add"`

5. **Submit the approval vote**:
   - No MCP tool supports setting reviewer votes directly, so use `Bash` with `az rest`:
     ```bash
     az rest --method PUT --url "https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repoId}/pullrequests/{prId}/reviewers/{reviewerId}?api-version=7.0" --body "{\"vote\": 10}" --headers "Content-Type=application/json" --resource "499b84ac-1321-427f-aa17-267ca6975798"
     ```
   - **IMPORTANT**: The `--resource '499b84ac-1321-427f-aa17-267ca6975798'` parameter is required for Azure DevOps authentication with `az rest`. Without it, the command fails to acquire an access token.

   Vote values:
   - `10` = Approved
   - `5` = Approved with suggestions
   - `0` = No vote
   - `-5` = Waiting for author
   - `-10` = Rejected

### Step 3: Report Results

After processing all PRs, provide a summary:

| PR | Platform | Status |
|----|----------|--------|
| {link} | GitHub/ADO | Approved / Failed (reason) |

## Error Handling

- **Not a reviewer (ADO)**: If the current user is not a reviewer on the PR, the vote API will fail. Inform the user they need to be added as a reviewer first.
- **No permissions (GitHub)**: If `gh pr review --approve` fails with a permissions error, inform the user.
- **Already approved**: If the PR is already approved, note it in the summary and continue to the next PR.
- **PR not found / merged / abandoned**: Skip and report the status.

## Guidelines

- Always confirm with the user before approving if the list is large (more than 5 PRs)
- Process PRs sequentially to provide clear progress tracking
- For ADO PRs, cache the repository ID and reviewer ID when multiple PRs are in the same repo to avoid redundant lookups
- Never approve PRs without the user explicitly requesting it
- Report any failures clearly so the user can take manual action

## Tool Usage Reference

| Task | Tool | Details |
|------|------|---------|
| Approve GitHub PR | `Bash` | `gh pr review {number} --repo {owner}/{repo} --approve` |
| Get ADO repo ID | `mcp__azure-devops__repo_get_repo_by_name_or_id` | `project`, `repositoryNameOrId` |
| Get ADO PR details | `mcp__azure-devops__repo_get_pull_request_by_id` | `repositoryId`, `pullRequestId` |
| Get ADO identity | `mcp__azure-devops__core_get_identity_ids` | `searchFilter` (email or display name) |
| Add ADO reviewer | `mcp__azure-devops__repo_update_pull_request_reviewers` | `repositoryId`, `pullRequestId`, `reviewerIds`, `action: "add"` |
| Submit ADO vote | `Bash` | `az rest --method PUT` to reviewers API with `{"vote": 10}` (REST fallback — no MCP vote tool) |
| Track progress | `TaskCreate` / `TaskUpdate` | Create todo items per PR, mark completed after approval |
