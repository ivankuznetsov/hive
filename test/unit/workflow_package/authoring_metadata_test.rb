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
