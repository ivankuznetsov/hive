# 2026-11-01 — Patch rack, crass and mail advisories

- `bundler-audit` began failing every Hive PR on new rack 3.2.6 advisories:
  GHSA-5v64-555j-wjxm (High, multipart scan-buffer memory exhaustion),
  GHSA-wvg4-6p58-3gh3 (Medium, `Rack::Static` header_rules bypass via dot
  segments) and GHSA-p8x9-v4hv-2w4g (Low, multipart boundary guard). Both
  `Gemfile.lock` and `web/Gemfile.lock` now pin rack 3.2.8.
- `web/Gemfile.lock` also carried crass 1.0.7 (CSS sanitizer bypass on bad
  URLs) and mail 2.9.0 (RFC 2047 encoded-word address spoofing), which the CI
  audit does not check because it only audits the root bundle. They are now
  crass 1.0.8 and mail 2.9.1.
- Conservative patch-level updates only (`bundle lock --update <gem>
  --conservative`); no other lockfile lines changed.
