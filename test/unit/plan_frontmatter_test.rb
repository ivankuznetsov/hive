require "test_helper"
require "hive/plan_frontmatter"

class PlanFrontmatterTest < Minitest::Test
  def test_absent_file_and_absent_frontmatter_have_no_assertion
    Dir.mktmpdir do |dir|
      missing = Hive::PlanFrontmatter.read(File.join(dir, "missing.md"))
      path = File.join(dir, "plan.md")
      File.write(path, "# Plan\n")
      plain = Hive::PlanFrontmatter.read(path)

      assert_equal :absent, missing.status
      assert_equal :absent, plain.status
      refute missing.depends_on_present?
      refute plain.depends_on_present?
    end
  end

  def test_frontmatter_without_dependency_is_valid
    result = read_plan("---\nexecution_mode: research\n---\n# Plan\n")

    assert_equal :ok, result.status
    assert_equal "research", result.data["execution_mode"]
    refute result.depends_on_present?
  end

  def test_matching_scalar_dependency_is_normalized
    result = read_plan("---\ndepends_on: analytics:base-task\n---\n# Plan\n")

    assert_equal :ok, result.status
    assert result.depends_on_present?
    assert_equal "analytics:base-task", result.depends_on.to_s
  end

  def test_duplicate_dependency_assertions_are_invalid
    result = read_plan(<<~MARKDOWN)
      ---
      depends_on: blocked-task
      depends_on: completed-task
      ---
      # Plan
    MARKDOWN

    assert_equal :invalid, result.status
    assert_match(/duplicate depends_on/, result.error)
  end

  def test_frontmatter_read_is_bounded_independently_of_plan_body
    body = "x" * (Hive::PlanFrontmatter::MAX_FRONTMATTER_BYTES * 2)
    result = read_plan("---\ndepends_on: base-task\n---\n#{body}")

    assert_equal :ok, result.status
    assert_equal "base-task", result.depends_on.to_s

    oversized = read_plan("---\nnotes: #{'x' * Hive::PlanFrontmatter::MAX_FRONTMATTER_BYTES}\n---\n")
    assert_equal :invalid, oversized.status
    assert_match(/malformed YAML frontmatter/, oversized.error)
  end

  def test_invalid_frontmatter_and_dependency_are_preserved_as_errors
    malformed = read_plan("---\ndepends_on: [unterminated\n---\n")
    unterminated = read_plan("---\ndepends_on: base-task\n")
    non_mapping = read_plan("---\n- depends_on: base-task\n---\n")
    invalid_dependency = read_plan("---\ndepends_on:\n  - one\n  - two\n---\n")

    assert_equal :invalid, malformed.status
    assert_equal :invalid, unterminated.status
    assert_equal :invalid, non_mapping.status
    assert_equal :invalid, invalid_dependency.status
    assert_match(/frontmatter/, malformed.error)
    assert_match(/mapping/, non_mapping.error)
    assert_match(/depends_on/, invalid_dependency.error)
  end

  private

  def read_plan(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "plan.md")
      File.write(path, contents)
      return Hive::PlanFrontmatter.read(path)
    end
  end
end
