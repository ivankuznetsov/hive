require "test_helper"
require "hive/commands/status"
require "hive/status_projection"
require "hive/tui/state_source"

class StatusProjectionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_action_label_order_is_frozen_and_terminates_with_error
    order = Hive::StatusProjection::ACTION_LABEL_ORDER

    refute_empty order
    assert order.frozen?
    assert_equal "Error", order.last
  end

  def test_label_position_ranks_known_labels_by_order_and_unknown_last
    order = Hive::StatusProjection::ACTION_LABEL_ORDER

    assert_equal 0, Hive::StatusProjection.label_position(order.first)
    assert_operator(
      Hive::StatusProjection.label_position("Ready to brainstorm"), :<,
      Hive::StatusProjection.label_position("Agent running")
    )
    assert_equal order.length,
                 Hive::StatusProjection.label_position("Totally unknown label")
  end

  # The command boundary re-exports the projection-owned constant so label
  # grouping and the TUI can never drift onto two different orders.
  def test_commands_status_reexports_the_projection_owned_order
    assert_same(
      Hive::StatusProjection::ACTION_LABEL_ORDER,
      Hive::Commands::Status::ACTION_LABEL_ORDER
    )
  end

  def test_archive_payload_from_cache_swaps_tasks_for_cached_rows
    ordinary = payload_with_projects([
                                       project("alpha", "/tmp/alpha",
                                               tasks: [ row("active-1") ],
                                               hidden: 3),
                                       project("beta", "/tmp/beta",
                                               tasks: [ row("active-2") ], hidden: 0)
                                     ])
    cache = { rows_by_path: {
      "/tmp/alpha" => [ row("archived-1") ].freeze,
      "/tmp/beta" => [].freeze
    }.freeze }

    merged = Hive::StatusProjection.archive_payload_from_cache(ordinary, cache)

    assert_equal [ "archived-1" ], slugs_for(merged, "/tmp/alpha")
    assert_equal [], slugs_for(merged, "/tmp/beta")
    merged["projects"].each do |project|
      refute project.key?("hidden_archived_task_count")
    end
  end

  def test_archive_payload_from_cache_degrades_error_projects_to_no_rows
    ordinary = payload_with_projects([ project("broken", "/tmp/broken", error: true) ])
    cache = { rows_by_path: { "/tmp/broken" => [ row("archived-1") ].freeze }.freeze }

    merged = Hive::StatusProjection.archive_payload_from_cache(ordinary, cache)

    assert_equal [], slugs_for(merged, "/tmp/broken")
  end

  def test_merge_visible_archived_payload_appends_rows_outside_active_folders
    ordinary = payload_with_projects([
                                       project("alpha", "/tmp/alpha",
                                               tasks: [ row("active-1", folder: "/a/one") ],
                                               hidden: 0)
                                     ])
    cache = {
      visible_rows_by_path: {
        "/tmp/alpha" => [
          row("archived-1", folder: "/a/one"),
          row("archived-2", folder: "/a/two")
        ].freeze
      }.freeze,
      hidden_counts_by_path: { "/tmp/alpha" => 4 }.freeze
    }

    merged = Hive::StatusProjection.merge_visible_archived_payload(ordinary, cache)
    project = merged.fetch("projects").fetch(0)

    assert_equal %w[active-1 archived-2], project.fetch("tasks").map { |r| r.fetch("slug") }
    assert_equal 4, project.fetch("hidden_archived_task_count")
  end

  def test_merge_visible_archived_payload_degrades_error_projects
    ordinary = payload_with_projects([ project("broken", "/tmp/broken", error: true) ])
    cache = {
      visible_rows_by_path: { "/tmp/broken" => [ row("archived-1") ].freeze }.freeze,
      hidden_counts_by_path: { "/tmp/broken" => 9 }.freeze
    }

    merged = Hive::StatusProjection.merge_visible_archived_payload(ordinary, cache)
    project = merged.fetch("projects").fetch(0)

    assert_equal [], project.fetch("tasks")
    assert_equal 0, project.fetch("hidden_archived_task_count")
  end

  # Composition helpers treat Status payloads as immutable inputs: the
  # caller's hashes must survive an archival merge untouched.
  def test_composition_helpers_do_not_mutate_their_inputs
    ordinary = payload_with_projects(
      [ project("alpha", "/tmp/alpha", tasks: [ row("active-1") ], hidden: 2) ]
    )
    ordinary_before = Marshal.dump(ordinary)
    cache = {
      rows_by_path: { "/tmp/alpha" => [ row("archived-1") ].freeze }.freeze,
      visible_rows_by_path: { "/tmp/alpha" => [ row("archived-1") ].freeze }.freeze,
      hidden_counts_by_path: { "/tmp/alpha" => 5 }.freeze
    }

    Hive::StatusProjection.archive_payload_from_cache(ordinary, cache)
    Hive::StatusProjection.merge_visible_archived_payload(ordinary, cache)

    assert_equal ordinary_before, Marshal.dump(ordinary)
  end

  # Regression: the TUI data boundary must not reach into the command
  # boundary for presentation ordering or re-implement archive payload
  # composition. Both decisions live on the internal status projection
  # boundary (`Hive::StatusProjection`).
  def test_tui_consumes_the_projection_boundary_instead_of_the_command_boundary
    snapshot_source = File.read(File.join(ROOT, "lib", "hive", "tui", "snapshot.rb"))
    state_source_code = File.read(File.join(ROOT, "lib", "hive", "tui", "state_source.rb"))

    refute_includes snapshot_source, "Commands::Status::"
    assert_includes snapshot_source, "Hive::StatusProjection"
    refute_match(/def (archive_payload_from_cache|merge_visible_archived_payload)/,
                 state_source_code)
    assert_includes state_source_code, "Hive::StatusProjection."
  end

  private

  def payload_with_projects(projects)
    { "generated_at" => "2026-07-24T12:00:00Z", "projects" => projects }
  end

  def project(name, path, tasks: [], hidden: nil, error: nil)
    project = {
      "name" => name,
      "path" => path,
      "hive_state_path" => "#{path}/.hive-state",
      "error" => error,
      "tasks" => tasks
    }
    project["hidden_archived_task_count"] = hidden unless hidden.nil?
    project
  end

  def row(slug, folder: "/a/#{slug}")
    { "slug" => slug, "folder" => folder, "action_label" => "Agent running" }
  end

  def slugs_for(payload, path)
    payload.fetch("projects")
           .find { |p| p.fetch("path") == path }
           .fetch("tasks")
           .map { |r| r.fetch("slug") }
  end
end
