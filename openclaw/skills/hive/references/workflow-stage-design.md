# Workflow stage design

Use the fewest stages that preserve distinct ownership, durable artifacts, or
material decisions. A verb phrase in the request is not automatically a stage.

- Split work when it produces a reusable artifact consumed later, needs a
  different actor/permission boundary, or must wait durably for a person.
- Keep ordinary transformations sequential. Do not infer speculative branches.
- Give each agent stage one focused instruction: inputs, required output,
  completion criteria, and explicit non-goals.
- Prefer project agent/model inheritance. Specialize only when the request
  materially requires a capability the inherited choice cannot supply.
- Use safe lowercase-hyphen stage names and distinct state files.
- A terminal human approval can complete with an artifact; it does not need a
  synthetic “done” or “publish” stage.

Before writing, restate the inferred ordered graph, artifacts, inheritance,
permissions, and decision points. Ask only when two plausible interpretations
would materially change behavior or consequences.
