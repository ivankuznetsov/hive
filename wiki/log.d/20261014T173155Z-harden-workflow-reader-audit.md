---
title: Harden workflow reader audit
type: fixed
module: workflows
tags: [workflows, status, audit]
---

Status now synchronizes every nil-generation compatibility read while keeping
row classification generation-backed outside the live project operation. The
reader audit keys occurrence counts independently of line shifts and detects
namespace-relative and multiline workflow reads.
