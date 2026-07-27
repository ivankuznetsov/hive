# Workflow permissions

For ordinary local agent stages created from natural language, use
`permissions: yolo`; this preserves Hive’s normal local execution semantics.
Omit stage agent/model fields to inherit project choices.

Do not silently grant external authority. Publishing, deployment, messaging,
credential use, production mutation, release operations, and destination
selection require an explicit destination and authorization outside inferred
workflow creation. Represent an approval request as a human stage; do not hide
it in an agent prompt.

Use a narrower supported permission scope only when the request clearly needs
it and the selected agent can enforce it. If enforcement capability or the
required directories/tools are unclear, ask one material question rather than
inventing a scope that may be ineffective.
