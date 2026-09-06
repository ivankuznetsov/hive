# Config::DEFAULTS is the sole owner of the wiki defaults reference

**Problem:** `wiki/modules/config.md` hand-maintained a partial literal copy of
`Hive::Config::DEFAULTS`. It drifted from the runtime owner, including a stale
`review.max_wall_clock_sec`, omitted complete configuration sections, and used
ellipses in place of live nested values. Nothing failed when that copy became
stale.

**Fix:** `lib/hive/config_defaults_doc.rb` now compiles the entire runtime
constant into the page's one managed region. The pure full-page renderer:

- serializes with an explicit PP width, insertion order, and LF policy rather
  than ambient terminal width;
- scans the complete binary page and accepts exactly one ordered pair of exact,
  standalone, LF-terminated marker lines;
- rejects missing, partial, duplicate, nested, reversed, inline, indented,
  altered, or non-LF marker structures before mutation; and
- preserves every byte before and after the managed region.

`script/generate-config-defaults-doc` is the maintainer-owned refresh path. It
uses that renderer and writes only when the complete expected page differs, so
an immediate second refresh is a no-write operation. The discovered unit test
uses the same renderer as a read-only whole-page drift guard; it never calls the
writer, and malformed pages cannot false-pass through first-match extraction.

Human-authored explanation remains outside the managed region, while per-value
commentary stays next to `Config::DEFAULTS` in `lib/hive/config.rb`. Runtime,
public CLI, schemas, templates, and unrelated wiki marker systems are
unchanged.
