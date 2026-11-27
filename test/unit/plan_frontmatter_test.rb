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
      assert_nil missing.depends_on
      assert_nil plain.depends_on
    end
  end

  def test_frontmatter_without_dependency_is_valid
    result = read_plan("---\nexecution_mode: research\n---\n# Plan\n")

    assert_equal :ok, result.status
    assert_equal "research", result.data["execution_mode"]
    assert_nil result.depends_on
  end

  def test_matching_scalar_dependency_is_normalized
    result = read_plan("---\ndepends_on: analytics:base-task\n---\n# Plan\n")

    assert_equal :ok, result.status
    assert_equal "analytics:base-task", result.depends_on.to_s
  end

  def test_dependency_arrays_preserve_shape_and_order
    result = read_plan(<<~MARKDOWN)
      ---
      depends_on:
        - base-task
        - analytics:other-task
        - base-task
      ---
      # Plan
    MARKDOWN

    assert_equal :ok, result.status
    assert_equal [ "base-task", "analytics:other-task" ], result.depends_on.map(&:to_s)
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
    invalid_dependency = read_plan("---\ndepends_on:\n  - one\n  -\n---\n")

    assert_equal :invalid, malformed.status
    assert_equal :invalid, unterminated.status
    assert_equal :invalid, non_mapping.status
    assert_equal :invalid, invalid_dependency.status
    assert_match(/frontmatter/, malformed.error)
    assert_match(/mapping/, non_mapping.error)
    assert_match(/depends_on/, invalid_dependency.error)
    assert_equal :malformed_yaml, malformed.invalid_kind
    assert_equal :malformed_frontmatter, unterminated.invalid_kind
    assert_equal :non_mapping, non_mapping.invalid_kind
    assert_equal [ { "depends_on" => "base-task" } ], non_mapping.raw_depends_on
    assert_equal :invalid_depends_on, invalid_dependency.invalid_kind
    assert_equal [ "one", nil ], invalid_dependency.raw_depends_on
    assert_equal [ 1 ], invalid_dependency.issues.map(&:index)
    assert_equal [ 0 ], invalid_dependency.entries.map(&:index)
  end

  def test_duplicate_keys_and_task_code_lists_preserve_structured_offending_evidence
    duplicate = Hive::PlanFrontmatter.parse(<<~MARKDOWN)
      ---
      depends_on: blocked-task
      depends_on:
        - completed-task
      ---
      # Plan
    MARKDOWN
    codes = Hive::PlanFrontmatter.parse(<<~MARKDOWN)
      ---
      depends_on:
        - C4
        - valid-task
        - F2
        - F3
      ---
      # Plan
    MARKDOWN

    assert_equal :duplicate_depends_on, duplicate.invalid_kind
    assert_equal [ "blocked-task", [ "completed-task" ] ], duplicate.raw_depends_on
    assert_equal 2, duplicate.issues.length

    assert_equal :invalid_depends_on, codes.invalid_kind
    assert_equal [ 0, 2, 3 ], codes.issues.map(&:index)
    assert_equal %w[C4 F2 F3], codes.issues.map(&:raw_value)
    assert_equal [ [ 1, "valid-task" ] ],
                 codes.entries.map { |entry| [ entry.index, entry.reference.to_s ] }
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
