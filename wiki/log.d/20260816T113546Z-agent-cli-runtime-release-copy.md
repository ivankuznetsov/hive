# Agent CLI Runtime explains its integration value

**Action:** Reframed the public README and gem metadata around the stable Ruby
integration layer that applications receive across Claude Code, Codex CLI, Pi,
Grok CLI, and OpenCode. The copy now leads with shared requests, installed
capability checks, normalized usage and results, and easier provider changes.

**Release notes:** Reworked the 0.2.0 changelog into a benefit-led account of
first-class OpenCode support: exact route selection, per-invocation isolated
configuration, scoped permissions, offline readiness checks, typed outcomes,
and accurate usage evidence.

**Distribution:** Hive remains the canonical component source. The standalone
GitHub repository receives these files through the component mirror workflow,
and the gemspec copy becomes RubyGems metadata on the next published version.
