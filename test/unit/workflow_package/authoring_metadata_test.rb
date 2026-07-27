require "test_helper"
require "hive/workflow_package/authoring_metadata"

class WorkflowPackageAuthoringMetadataTest < Minitest::Test
  include HiveTestHelper

  Metadata = Hive::WorkflowPackage::AuthoringMetadata

  def test_loads_the_closed_authored_contract_and_validates_readme_topics
    with_tmp_dir do |dir|
      path = File.join(dir, "honeycomb.yml")
      File.write(path, valid_metadata_yaml)

      metadata = Metadata.load(path)

      assert_equal "A deterministic example workflow", metadata.description
      assert_equal "Test Author", metadata.author.fetch("name")
      assert_equal %w[assets/context.md tools/check.rb], metadata.assets
      assert Metadata.validate_readme!(valid_readme, path: "README.md")
    end
  end

  def test_rejects_unknown_fields_duplicates_placeholders_and_bad_provenance
    variants = {
      "unknown field" => valid_metadata_yaml + "version: 1.0.0\n",
      "duplicate field" => valid_metadata_yaml + "description: Duplicate\n",
      "placeholder" => valid_metadata_yaml.sub("Test Author", "Your name"),
      "source revision" => valid_metadata_yaml.sub("a" * 40, "main")
    }

    variants.each do |label, bytes|
      with_tmp_dir do |dir|
        path = File.join(dir, "honeycomb.yml")
        File.write(path, bytes)
        error = assert_raises(Hive::ConfigError, label) { Metadata.load(path) }
        refute_includes error.message, "A deterministic example workflow"
      end
    end
  end

  def test_each_readme_topic_requires_non_placeholder_content
    Metadata::README_SECTIONS.each do |section|
      invalid = valid_readme.sub("Useful #{section.downcase} details.", "TODO")
      error = assert_raises(Hive::ConfigError) do
        Metadata.validate_readme!(invalid, path: "README.md")
      end
      assert_includes error.message, section
    end
  end

  def test_rejects_each_closed_metadata_field_boundary
    variants = {
      "compound license" => valid_metadata_yaml.sub("license: MIT", "license: MIT OR Apache-2.0"),
      "invalid minimum" => valid_metadata_yaml.sub("hive_min_version: 0.6.5", "hive_min_version: latest"),
      "author shape" => valid_metadata_yaml.sub(
        "author:\n  name: Test Author\n  url: https://example.test/authors/test\n",
        "author:\n  name: Test Author\n"
      ),
      "source shape" => valid_metadata_yaml.sub(
        "source:\n  url: https://example.test/source/demo\n  revision: #{'a' * 40}\n",
        "source:\n  url: https://example.test/source/demo\n"
      ),
      "asset type" => valid_metadata_yaml.sub("assets:\n", "assets: value\n"),
      "asset path" => valid_metadata_yaml.sub("  - assets/context.md", "  - ../outside"),
      "credential URL" => valid_metadata_yaml.sub("https://example.test/authors/test", "https://user@example.test/author"),
      "invalid URL" => valid_metadata_yaml.sub("https://example.test/authors/test", "http://[")
    }

    variants.each do |label, bytes|
      with_tmp_dir do |dir|
        path = File.join(dir, "honeycomb.yml")
        File.write(path, bytes)
        assert_raises(Hive::ConfigError, label) { Metadata.load(path) }
      end
    end
  end

  def test_safe_yaml_and_bounded_file_edges_fail_closed
    [
      "",
      "---\na: b\n---\nc: d\n",
      "1: value\n",
      "? [a, b]\n: value\n",
      "a: [\n"
    ].each do |bytes|
      assert_raises(Hive::ConfigError) do
        Metadata.parse_yaml_map(bytes, label: "fixture")
      end
    end

    with_tmp_dir do |dir|
      assert_raises(Hive::ConfigError) { Metadata.load(File.join(dir, "missing.yml")) }
      assert_raises(Hive::ConfigError) { Metadata.load(dir) }
      link = File.join(dir, "honeycomb.yml")
      target = File.join(dir, "target.yml")
      File.write(target, valid_metadata_yaml)
      File.symlink(target, link)
      assert_raises(Hive::ConfigError) { Metadata.load(link) }
    end
  end

  private

  def valid_metadata_yaml
    <<~YAML
      description: A deterministic example workflow
      author:
        name: Test Author
        url: https://example.test/authors/test
      license: MIT
      hive_min_version: 0.6.5
      source:
        url: https://example.test/source/demo
        revision: #{"a" * 40}
      assets:
        - assets/context.md
        - tools/check.rb
    YAML
  end

  def valid_readme
    <<~MARKDOWN
      # Demo

      #{Metadata::README_SECTIONS.map { |section| "## #{section}\n\nUseful #{section.downcase} details.\n" }.join("\n")}
    MARKDOWN
  end
end
