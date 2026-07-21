# Content research

> **Deterministic replay fixture.** Links were intentionally selected for this
> example; this file is not a live research-agent result.

- Hive stores task state as files and stage folders:
  https://github.com/ivankuznetsov/hive/blob/main/docs/architecture.md
- Built-in content stages preserve research, outline, draft, critique, and the
  final article:
  https://github.com/ivankuznetsov/hive/blob/main/docs/workflows.md
- Status and web surfaces read the same durable task state:
  https://github.com/ivankuznetsov/hive/blob/main/wiki/commands/web.md

Limitation to retain: durable local state does not make external providers or
network services available.
