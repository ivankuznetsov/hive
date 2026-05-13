# Composer image-paste fixtures

`screenshot-1.png`, `screenshot-2.png`, `screenshot-3.png` are minimal 1×1
PNGs (68 bytes each) used by `test/integration/tui_new_idea_attachments_smoke_test.rb`
to drive the fixture-clipboard probe path in `Hive::Tui::Clipboard`
(`HIVE_TUI_TEST_CLIPBOARD=fixture://...`).

The contract these fixtures honour:

1. **They are valid PNGs.** `Hive::Tui::Clipboard::probe_image_file` checks
   `File.extname` plus on-disk size; the smoke test then asserts
   `File.binread(asset) == File.binread(fixture)` after submit, so the
   bytes have to round-trip identically. Replacing them with non-PNG
   payloads (raw bytes, zero-byte files, JPEGs renamed `.png`) breaks
   the contract even if the file size still looks "small enough".
2. **They are distinguishable across the three slots.** The smoke test
   pastes three times in sequence; the fixture-clipboard probe clamps
   at the last fixture on overflow, so reusing identical contents
   across files would mask an off-by-one in the probe's index
   advance.
3. **They stay tiny.** 1×1 keeps the smoke test under the
   `MAX_IMAGE_BYTES` cap (10 MiB) without bumping the fixture size if
   the test needs to grow.

If you need to regenerate these, the 68-byte 1×1 PNG construction is
canonical — keep the file size where it is so the fixture pin retains
its size-meaning.
