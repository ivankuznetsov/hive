---
title: Make the live proof candidate gem self-contained
date: 2026-07-22
tags: [release, live-agent, rubygems, ci]
---

Fixed the four-agent release proof's private gem installation. RubyGems writes
an executable stub that still needs the non-default install directory on
`GEM_HOME`/`GEM_PATH`; invoking that stub directly made every matrix job fail
after installation and before provider access. The workflow now installs the
raw stub behind a self-contained wrapper that restores the private gem path on
every invocation and clears inherited Ruby/Bundler startup injection, including
when the proof harness invokes it from a Bundler-managed test process.

Added an offline regression that builds a dependency-free fixture gem,
installs it into a path containing spaces, clears inherited RubyGems path
variables, and proves the public wrapper can still execute the private gem.
