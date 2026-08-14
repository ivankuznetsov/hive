require "test_helper"
require "hive/patrol/finding_query"

class PatrolFindingQueryTest < Minitest::Test
  include HiveTestHelper

  def test_writer_projection_is_bounded_active_first_and_shared_by_query
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      30.times do |index|
        store.write_finding(finding(index, state: "active"))
      end
      store.write_finding(finding(30, state: "resolved"))
      store.update_state("last_run_at" => "2026-08-13T12:00:00Z")
      store.rebuild_finding_query_projection!

      payload = Hive::Patrol::FindingQuery.new(store).list_envelope(
        project: "demo", project_root: dir
      )

      assert_equal "hive-patrol-findings", payload.fetch("schema")
      assert_equal 31, payload.fetch("count")
      assert_equal({ "active" => 30, "resolved" => 1 }, payload.fetch("counts"))
      assert_equal 25, payload.fetch("findings").size
      assert_equal "finding-29", payload.dig("findings", 0, "id")
      assert_equal %w[
        category confidence description feature_id id lifecycle_state
        lifecycle_updated_at severity title
      ], payload.dig("findings", 0).keys.sort
      assert payload.fetch("truncated")
      assert_equal "2026-08-13T12:00:00Z", payload.fetch("last_run_at")
    end
  end

  def test_text_renders_summary_and_each_finding
    payload = {
      "project" => "demo",
      "count" => 2,
      "counts" => { "active" => 1 },
      "findings" => [
        {
          "id" => "finding-1", "lifecycle_state" => "active",
          "severity" => "high", "title" => "Broken boundary"
        },
        {
          "id" => "finding-2", "severity" => "low", "category" => "bug"
        }
      ]
    }

    text = Hive::Patrol::FindingQuery.new(Object.new).text(payload)

    assert_equal <<~OUTPUT.chomp, text
      hive patrol findings: demo count=2 active=1 returned=2
      finding-1 state=active severity=high Broken boundary
      finding-2 state=active severity=low bug
    OUTPUT
  end

  def test_projection_treats_an_invalid_lifecycle_timestamp_as_oldest
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      invalid = finding(1, state: "active")
      invalid.lifecycle_updated_at = "not-a-timestamp"
      store.write_finding(invalid)
      store.write_finding(finding(2, state: "active"))

      projection = store.rebuild_finding_query_projection!

      assert_equal %w[finding-2 finding-1],
                   projection.fetch("items").map { |item| item.fetch("id") }
    end
  end

  def test_projection_caps_summary_strings_and_omits_full_finding_evidence
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      value = finding(1, state: "active")
      value.description = "é" * 10_000
      value.evidence = [ { "path" => "/private/source.rb", "snippet" => "secret" } ]
      value.reproduction = { "command" => "cat /private/source.rb" }
      store.write_finding(value)
      store.rebuild_finding_query_projection!

      item = store.finding_query_projection.fetch("items").first

      assert_operator item.fetch("description").bytesize, :<=, 4 * 1024
      assert_predicate item.fetch("description"), :valid_encoding?
      refute item.key?("evidence")
      refute item.key?("reproduction")
      assert_operator File.size(File.join(store.root, "finding-query.json")),
                      :<=, Hive::Patrol::StateStore::FINDING_QUERY_MAX_BYTES
    end
  end

  def test_oversized_projection_fails_closed_without_an_unbounded_read
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      File.binwrite(
        File.join(store.root, "finding-query.json"),
        "x" * (Hive::Patrol::StateStore::FINDING_QUERY_MAX_BYTES + 1)
      )

      error = assert_raises(Hive::ConfigError) do
        store.finding_query_projection
      end
      assert_match(/projection is unavailable/, error.message)
    end
  end

  def test_interrupted_projection_write_leaves_the_dirty_marker
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      store.write_finding(finding(1, state: "active"))
      directory = store.instance_variable_get(:@cycle_directory)
      directory.define_singleton_method(:atomic_write) do |*|
        raise Errno::ENOSPC, "injected"
      end

      assert_raises(Errno::ENOSPC) { store.rebuild_finding_query_projection! }
      assert_path_exists File.join(store.root, "finding-query.dirty")
      assert_raises(Hive::ConfigError) { store.finding_query_projection }
    end
  end

  def test_dirty_projection_fails_closed_until_writer_lifecycle_repairs_it
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      store.with_cycle_lock { nil }
      store.write_finding(finding(1, state: "active"))
      File.write(File.join(store.root, "finding-query.dirty"), "dirty\n")

      assert_raises(Hive::ConfigError) { store.finding_query_projection }

      store.with_cycle_lock { nil }
      assert_equal 1, store.finding_query_projection.fetch("total")
      refute_path_exists File.join(store.root, "finding-query.dirty")
    end
  end

  private

  def finding(index, state:)
    Hive::Patrol::Finding.new(
      id: "finding-#{index}", feature_id: "feature-#{index}",
      category: "bug", severity: "medium", confidence: "high",
      title: "Finding #{index}", description: "Evidence #{index}",
      lifecycle_state: state,
      lifecycle_updated_at: (Time.utc(2026, 8, 13) + index).iso8601
    )
  end
end
