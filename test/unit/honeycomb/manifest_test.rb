require "test_helper"
require "digest"
require "hive/honeycomb/manifest"

class HoneycombManifestTest < Minitest::Test
  include HiveTestHelper

  def test_hashes_all_final_files_except_itself_with_documented_tuple_digest
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "nested"))
      File.binwrite(File.join(dir, "workflow.yml"), "id: test\n")
      File.binwrite(File.join(dir, "README.md"), "Read me\n")
      File.binwrite(File.join(dir, "nested", "asset.bin"), "\x00\xff".b)

      manifest = Hive::Honeycomb::Manifest.write(
        package_root: dir,
        id: "test",
        metadata: {
          "version" => "1.0.0", "author" => "Author", "description" => "Description",
          "minimum_hive_version" => "0.3.7"
        },
        dependencies: [],
        permission_summary: { "contexts" => [], "aggregate" => {} },
        review_required: []
      )

      paths = manifest.fetch("files").map { |row| row.fetch("path") }
      assert_equal %w[README.md nested/asset.bin workflow.yml], paths
      refute_includes paths, "manifest.yml"
      tuple_bytes = manifest.fetch("files").map do |row|
        "#{row.fetch('path')}\0#{row.fetch('sha256')}\n"
      end.join
      assert_equal Digest::SHA256.hexdigest(tuple_bytes), manifest.fetch("aggregate_sha256")
      assert_equal manifest, YAML.safe_load(File.read(File.join(dir, "manifest.yml")))
      refute_includes File.read(File.join(dir, "manifest.yml")), dir
    end
  end

  def test_package_cleanup_removes_only_its_package_root
    with_tmp_dir do |dir|
      package_root = File.join(dir, "workflows", "test")
      FileUtils.mkdir_p(package_root)
      File.write(File.join(package_root, "workflow.yml"), "id: test\n")
      package = Hive::Honeycomb::Package.new(
        staging_root: dir,
        package_root: package_root,
        id: "test",
        version: "1.0.0",
        metadata: {},
        owners: {},
        dependencies: [],
        permission_summary: {},
        manifest: {}
      )

      package.cleanup!

      refute File.exist?(package_root)
      assert File.directory?(dir)
    end
  end
end
