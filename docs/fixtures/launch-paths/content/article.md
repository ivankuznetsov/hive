# The handoff that survived a laptop restart

> **Deterministic replay fixture.** This is an intentionally public synthetic
> output, not private corpus material, live provider completion, or timing
> evidence.

The laptop closed halfway through the job. The conversation disappeared, but
the brief, source notes, outline, and current marker were still ordinary files
in the task folder. Hive's
[file-backed state](https://github.com/ivankuznetsov/hive/blob/main/docs/architecture.md)
made the interruption inspectable instead of mysterious.

A new agent can read what was accepted, open the latest artifact, and follow
the next action. It does not need a perfect recap from the previous process.
Research, outline, draft, critique, and final copy remain separate, so a human
can see where the work changed rather than receiving one unexplained blob.

Durable state is not provider availability. If an API reaches a limit, Hive can
preserve the files and surface the hold; it cannot make the provider available.
When the dependency recovers, the same stage has a bounded place to resume.

Try the inspection step first: open a task in Hive web and expand **Artifacts**
before you press **Approve** or **Retry stage**. The handoff is the evidence you
can read, not a promise that the previous process stayed alive.
