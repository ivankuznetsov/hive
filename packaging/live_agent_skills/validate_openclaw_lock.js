#!/usr/bin/env node

"use strict";

const fs = require("fs");

const [lockPath, version, integrity] = process.argv.slice(2);
if (!lockPath || !version || !integrity) {
  throw new Error("usage: validate_openclaw_lock.js LOCK VERSION INTEGRITY");
}

const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const packages = lock.packages;
if (lock.lockfileVersion !== 3 || !packages || typeof packages !== "object") {
  throw new Error("OpenClaw npm lock must be lockfileVersion 3");
}
const root = packages[""];
if (!root || JSON.stringify(root.dependencies) !== JSON.stringify({ openclaw: version })) {
  throw new Error("OpenClaw npm lock root identity changed");
}
for (const [relative, entry] of Object.entries(packages)) {
  if (relative === "") continue;
  if (
    !entry ||
    entry.link === true ||
    typeof entry.version !== "string" ||
    typeof entry.resolved !== "string" ||
    !entry.resolved.startsWith("https://registry.npmjs.org/") ||
    typeof entry.integrity !== "string" ||
    !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(entry.integrity)
  ) {
    throw new Error(`mutable npm lock entry: ${relative}`);
  }
}
const openclaw = packages["node_modules/openclaw"];
if (!openclaw || openclaw.version !== version || openclaw.integrity !== integrity) {
  throw new Error("OpenClaw npm lock package identity changed");
}
