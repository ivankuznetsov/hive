require "test_helper"
require "digest"
require "hive/honeycomb/diff"

class HoneycombDiffTest < Minitest::Test
  include HiveTestHelper

  def test_reports_permission_escalation_and_full_instruction_diff
    with_tmp_dir do |root|
      old_root = File.join(root, "old")
      old_package = package_at(old_root, body: "first\nsecond\n", tools: [ "Read" ], sha: "1" * 40)
      new_package = package_at(File.join(root, "new"), body: "first\nchanged\nthird\n",
                               tools: %w[Read Bash], sha: "2" * 40)
      entry = Hive::Honeycomb::LockEntry.from_verified(old_package)

      diff = Hive::Honeycomb::Diff.build(entry: entry, package: new_package, installed_root: old_root)

      assert_equal true, diff.escalation
      assert_equal [ "Bash" ], diff.permissions.fetch("tools").fetch("added")
      unified = diff.instruction_diffs.fetch("instructions/work.md")
      assert_includes unified, "--- a/instructions/work.md"
      assert_includes unified, "+++ b/instructions/work.md"
      assert_includes unified, "-second"
      assert_includes unified, "+changed"
      assert_includes unified, "+third"
      assert_empty diff.asset_changes.fetch("changed")
    end
  end

  def test_descriptor_and_binary_asset_only_changes_are_summarized
    with_tmp_dir do |root|
      old_root = File.join(root, "old")
      old_package = package_at(old_root, body: "same\n", tools: [ "Read" ], asset: "old".b, sha: "1" * 40)
      new_package = package_at(File.join(root, "new"), body: "same\n", tools: [ "Read" ],
                               asset: "new\x00".b, sha: "2" * 40, state_file: "result.md")
      diff = Hive::Honeycomb::Diff.build(
        entry: Hive::Honeycomb::LockEntry.from_verified(old_package), package: new_package, installed_root: old_root
      )

      assert_equal true, diff.descriptor_changed
      assert_equal [ "asset.bin" ], diff.asset_changes.fetch("changed")
      assert_empty diff.instruction_diffs
      assert_equal false, diff.metadata_only
    end
  end

  def test_private_fallback_and_unified_diff_error_paths
    with_tmp_dir do |root|
      File.write(File.join(root, "workflow.yml"), "invalid: true\n")
      assert_equal [ "fallback.md" ],
                   Hive::Honeycomb::Diff.instruction_inventory(root, "demo", %w[fallback.md asset.bin])
      assert_nil Hive::Honeycomb::Diff.read_optional(File.join(root, "missing.md"))
      assert_equal "", Hive::Honeycomb::Diff.unified("same.md", "same\n", "same\n")

      status = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
      with_replaced_singleton_method(Open3, :capture3, ->(*_args) { [ "", "bad diff", status.new(2) ] }) do
        assert_raises(Hive::InternalError) { Hive::Honeycomb::Diff.unified("bad.md", "old", "new") }
      end
      with_replaced_singleton_method(Open3, :capture3, ->(*_args) { raise Errno::ENOENT, "diff" }) do
        fallback = Hive::Honeycomb::Diff.unified("fallback.md", "old\n", "new\n")
        assert_includes fallback, "-old"
        assert_includes fallback, "+new"
      end
    end
  end

  private

  def package_at(root, body:, tools:, sha:, asset: "asset".b, state_file: "work.md")
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.binwrite(File.join(root, "instructions", "work.md"), body)
    File.binwrite(File.join(root, "asset.bin"), asset)
    File.write(File.join(root, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: work
          kind: agent
          state_file: #{state_file}
          instruction: ./instructions/work.md
          permissions:
            preset: scoped
            tools: [#{tools.join(', ')}]
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    files = %w[workflow.yml instructions/work.md asset.bin].to_h do |path|
      [ path, Digest::SHA256.file(File.join(root, path)).hexdigest ]
    end
    manifest = Hive::Honeycomb::Manifest.load({
      "version" => 1, "files" => files,
      "permissions" => { "presets" => [ "scoped" ], "tools" => tools, "dirs" => [],
                           "bash" => tools.include?("Bash"), "yolo" => false }
    }.to_yaml)
    pin = Hive::Honeycomb::ResolvedPin.new(
      source: Hive::Honeycomb::SOURCE, name: "demo", sha: sha, version: "1.0.0", tag: "demo/v1.0.0",
      digest: manifest.package_digest, selector_kind: "latest", selector_value: nil
    )
    descriptor = Hive::Workflows::DescriptorParser.parse_file(File.join(root, "workflow.yml"), expected_id: "demo")
    report = Hive::Honeycomb::SecurityReport.build(workflow: descriptor, package_root: root)
    Hive::Honeycomb::VerifiedPackage.new(
      pin: pin, manifest: manifest,
      files: files.keys.to_h { |path| [ path, File.binread(File.join(root, path)) ] }, hashes: files,
      modes: files.keys.to_h { |path| [ path, "100644" ] }, descriptor: descriptor,
      security_report: report, staging_dir: root
    )
  end
end
