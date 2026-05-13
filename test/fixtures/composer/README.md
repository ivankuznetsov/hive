# Composer image-paste fixtures

`screenshot-1.png`, `screenshot-2.png`, `screenshot-3.png` are minimal
1×1 RGB PNGs (red, green, blue respectively) used by
`test/integration/tui_new_idea_attachments_smoke_test.rb` to drive the
fixture-clipboard probe path in `Hive::Tui::Clipboard`
(`HIVE_TUI_TEST_CLIPBOARD=fixture://...`).

The contract these fixtures honour:

1. **They are valid PNGs.** `Hive::Tui::Clipboard::probe_image_file`
   checks `File.extname` plus the on-disk magic-byte signature; the
   smoke test then asserts `File.binread(asset) == File.binread(fixture)`
   after submit, so the bytes have to round-trip identically.
2. **They are byte-distinct across the three slots.** The smoke test
   pastes three times in sequence and the per-asset binread comparison
   would silently pass on identical contents — the colour-per-fixture
   construction makes a regression in the probe's index-advance fail
   the binread check on at least one slot. Do NOT make the three files
   byte-identical "for simplicity"; the per-asset assertion goes
   vacuous and R16 (sequence-advance pin) is defeated.
3. **They stay tiny.** 1×1 RGB keeps the smoke test under the
   `MAX_IMAGE_BYTES` cap (10 MiB) with no per-fixture growth pressure
   if the test needs to add a fourth.

Regenerate with the Ruby snippet at the top of
`test/integration/tui_new_idea_attachments_smoke_test.rb` (and keep the
red/green/blue ordering so the smoke test's "first paste is red"
implicit assumption stays valid).
