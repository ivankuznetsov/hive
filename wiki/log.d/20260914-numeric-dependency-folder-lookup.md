## Resolve registered numeric dependencies by folder lookup

Active dependency lookup now reads the existing control-plane ID-to-slug
mapping scoped to a project state root, then checks only that folder name
across stages. Current metadata must still match the requested ID. No new
index, migration, or cache is introduced. Tasks not yet registered retain the
legacy discovery fallback. Regression coverage includes moved and replacement
folders, duplicate stage copies, project scoping, and absence of unrelated
metadata reads.
