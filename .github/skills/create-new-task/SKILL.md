---
name: create-new-task
description: Create a new ADO Task under a parent PBI with intelligent defaults. Use this when asked to create a new task, work item, or ADO task — especially when already working on a feature or addressing PR feedback.
---

Create a new Azure DevOps Task as a child of a parent Product Backlog Item (PBI). The task inherits Area Path and Iteration Path from the parent PBI.

## Phase 1: Determine the Parent PBI

You need a parent PBI ID. Determine it using one of these strategies, in priority order:

### Strategy A: Infer from Current Context

Check if the current session already involves a work item:

1. **Working on a task** (e.g., "implement feature described in task 12345"):
   - Fetch the task using `ado-wit_get_work_item` with `expand: relations`
   - Find the parent relation (`System.LinkTypes.Hierarchy-Reverse` with name "Parent")
   - Extract the parent PBI ID from the relation URL (last segment of the URL path)
   - The new task will be a **peer** of the current task (same parent PBI)

2. **Addressing PR feedback** (e.g., "address PR comments for PR #6789"):
   - Fetch the PR using `ado-repo_get_pull_request_by_id` with `includeWorkItemRefs: true`
   - Get the linked work item(s) from the PR
   - If **one work item** is linked: use it as the peer task and find its parent PBI (as in Strategy A.1)
   - If **multiple work items** are linked: **ask the user** which work item the new task should peer with — do NOT guess
   - If **no work items** are linked: fall through to Strategy B

3. **Session history**: Check the session store for recent work item references:
   ```sql
   SELECT ref_value FROM session_refs WHERE ref_type = 'workitem' ORDER BY created_at DESC LIMIT 5;
   ```

### Strategy B: Ask the User

If no parent PBI can be inferred, ask the user:
- "What is the parent PBI number for this new task?"
- Accept a PBI ID (number) or a full ADO URL (e.g., `https://msazure.visualstudio.com/One/_workitems/edit/36748505`)
- Parse the PBI ID from the URL if a URL is provided

### Validation

Once you have a candidate parent PBI ID:
1. Fetch it with `ado-wit_get_work_item` (include `fields: ["System.WorkItemType", "System.AreaPath", "System.IterationPath", "System.Title"]`)
2. Confirm `System.WorkItemType` is `"Product Backlog Item"`
3. If it's a Task instead, find *its* parent PBI (walk up the hierarchy)
4. If it's neither a PBI nor a Task, ask the user for clarification

## Phase 2: Gather Task Details

### Title
- If the user provided a task title, use it
- If the user provided a prompt/description but no title, derive a concise title from the prompt

### Description
- If the user provided a prompt or description for the new task, place it in the task description field
- Use HTML format for the description (the ADO API default)
- If no prompt was provided, leave the description empty

### Inherited Fields
From the parent PBI, extract and use:
- **Area Path** (`System.AreaPath`)
- **Iteration Path** (`System.IterationPath`)

## Phase 3: Create the Task

Use `ado-wit_add_child_work_items` to create the task:

```
Tool: ado-wit_add_child_work_items
Parameters:
  project: <project from parent PBI's System.TeamProject>
  parentId: <parent PBI ID>
  workItemType: "Task"
  items:
    - title: <task title>
      description: <task description or prompt, if any>
      areaPath: <inherited from parent PBI>
      iterationPath: <inherited from parent PBI>
```

## Phase 4: Report Results

After creating the task, report:
1. The new task ID and title
2. A link to the new task: `https://msazure.visualstudio.com/<project>/_workitems/edit/<task_id>`
3. The parent PBI ID and title it was created under
4. The inherited Area Path and Iteration Path

Example output:
```
Created Task #12345678: "Implement retry logic for blob storage"
  Parent PBI #36748505: "Make MrBot better"
  Area Path: One\AzureMessaging\Azure Messaging GeoReplication
  Iteration: One\Custom\AzureMessaging\Krypton\KrM3
  Link: https://msazure.visualstudio.com/One/_workitems/edit/12345678
```

## Key Principles

- **Always inherit Area Path and Iteration Path** from the parent PBI — never guess or use defaults
- **Never guess the parent PBI** when multiple candidates exist — ask the user to disambiguate
- **Peer tasks share a parent**: when creating a task alongside an existing task, find the common parent PBI
- **Prompts go in the description**: if the user provides a prompt or instructions for the task, put it in the description field so it's captured in ADO
- **Validate the parent type**: always confirm the parent is a PBI before creating the child task
