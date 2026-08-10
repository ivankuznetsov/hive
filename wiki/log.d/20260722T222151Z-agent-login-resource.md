---
title: Isolated Rails agent-login polling resource
date: 2026-07-22
tags: [web, rails, turbo, agents, performance]
---

Agent login create/show/completion now enter dedicated resource controllers and
an `AgentLogin` request snapshot instead of special actions on
`AgentsController`. The public verbs and URLs remain unchanged, while a status
refresh renders only its one PTY session and no longer reruns account checks,
registered-project loading, or selected-project managed-skill inventory.

Turbo frame requests omit a matching `src` that points back to the request URL;
Turbo rejects that recursive response and otherwise empties the frame. The
two-second poll controller is attached to replaceable inner content, with its
frame lookup supporting both that lifecycle and existing frame-owned polls.
When the CLI finishes, the completed server response replaces the controlled
content and Stimulus disconnects the timer without a client-owned completion
state.

Model and integration coverage pins immutable snapshots, session/agent URL
binding, route ownership, isolated rendering, and the non-recursive frame
contract. A Capybara/Playwright flow proves the provider URL renders without
the Agents inventory and that polling stops after completion.

**Links:** [[commands/web]], [[architecture]], [[testing]], [[decisions]]
