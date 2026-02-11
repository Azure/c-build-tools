---
name: save-skill
description: Save the current workflow discussion as a reusable skill. Use when the user wants to capture a repeatable workflow pattern for future use.
argument-hint: Optional skill name (e.g., "build-repo", "debug-tests")
---

Generalize the current discussion into a reusable skill that can be applied in similar contexts.

## Workflow

### Step 1: Analyze the Conversation
1. Review the conversation to identify the user's primary workflow, task, or capability pattern
2. If there is no conversation present, reply that the `/save-skill` command expects an active discussion to generalize. Keep the reply concise.
3. Identify the core capability that could be reused in similar scenarios

### Step 2: Generalize the Workflow
1. Extract the core capability, removing conversation-specific details:
   - Replace specific file paths with placeholders (e.g., `<repo_root>`, `<file_path>`)
   - Replace project names with generic terms (e.g., `<project_name>`, `<module_name>`)
   - Remove user-specific context
2. Identify common patterns and best practices from the workflow
3. Note any troubleshooting tips that emerged during the discussion

### Step 3: Create the Skill Definition
1. Create a concise skill name in hyphenated format (e.g., `build-repo`, `debug-tests`, `create-module`)
2. Write a clear description (max 1024 characters) explaining:
   - What the skill does
   - When it should be used
   - Key triggers or keywords that indicate this skill applies

### Step 4: Write the Skill Content
Structure the skill body with:
- Clear section headers using markdown
- Step-by-step procedures to follow
- Code examples with placeholders
- Common patterns and best practices
- Troubleshooting tips if applicable

### Step 5: Save the Skill
1. Create the skill directory under the skills location
2. Save the SKILL.md file with proper YAML frontmatter format

## Skill File Format

```markdown
---
name: <skill-name>
description: <Clear description of what the skill does and when it should be used>
argument-hint: <Brief hint about expected arguments, if any>
---

<Detailed instructions, guidelines, procedures, and examples>

## Workflow

### Step 1: <First Major Step>
- Sub-steps with details

### Step 2: <Next Major Step>
...

## Guidelines

- Best practices
- Common pitfalls to avoid
```

## Guidelines

- Skills are loaded on-demand when relevant to the user's request
- The `description` field is critical - it determines when to activate the skill
- Use the `argument-hint` field to guide users on what arguments the skill expects
- Keep skill names concise and descriptive using hyphenated format
- Use placeholders like `<module_name>`, `<file_path>`, `<target_name>` for customizable values
