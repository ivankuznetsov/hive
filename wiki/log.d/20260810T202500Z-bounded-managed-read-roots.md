# Fence bounded managed actors to declared read roots

- Stopped portable bounded Codex and Grok actors from inheriting the managed
  task's project root through trusted caller context.
- Kept task/package roots and descriptor `dirs` available, while explicit
  `yolo` actors retain their intentional project/worktree context.
- Rejected portable Codex/Grok mappings for file-qualified `Read(...)` scopes
  their directory-level sandboxes cannot enforce.
- Added Codex and Grok policy coverage for undeclared and declared roots.
