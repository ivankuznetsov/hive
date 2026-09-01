require "test_helper"
require "hive/task_workspace/builder"

class TaskWorkspaceBuilderCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  SECRET = "workspace-builder-coverage-secret-32-bytes".freeze
  Read = Hive::TaskProjection::Reader::BoundedRead
  Native = Data.define(:folder, :project_root, :slug, :id)

  class Task
    attr_accessor :values, :publication_value, :artifact_value, :recovery_value,
                  :predicate_error

    def initialize
      @values = {
        "slug" => "task", "id" => 42, "stage" => "4-execute",
        "marker" => nil, "attrs" => {}, "observation_mtime" => "bad"
      }
    end

    def [](key) = values[key]
    def publication(cache: nil) = publication_value
    def artifact_panel = artifact_value
    def recovery = recovery_value
    def recovery_context = [ "/private/context" ]
    def recovery_primary_label = "Retry"
    def dispatch_action = values["dispatch_action"]

    def passable?
      raise "predicate failed" if predicate_error

      values["passable"] == true
    end

    def recovery_action_visible? = values["recovery_visible"] == true
    def recovery_action_enabled? = values["recovery_enabled"] == true
  end

  class NoPanelsTask
    def initialize(values)
      @values = values
    end

    def [](key) = @values[key]
  end

  def test_projection_fallback_store_marker_and_default_clock
    with_fixture do |root, task, native|
      subject = builder(task, native)
      assert_kind_of Time, subject.instance_variable_get(:@clock).call

      store = Object.new
      store.define_singleton_method(:read_bounded) { |**| raise "projection failed" }
      subject.instance_variable_set(:@history_reader, store)
      read = subject.send(:history_read)
      assert_equal "partial", read.state
      assert_equal "bounded_projection_failed", read.diagnostics.first.fetch("reason")

      with_attempts = builder(task, native, attempt_store: Object.new)
      assert_instance_of Hive::TaskProjection::Reader, with_attempts.send(:history_reader)
      without_attempts = builder(task, native)
      assert_instance_of Hive::TaskProjection::Reader, without_attempts.send(:history_reader)

      marker = subject.send(:marker)
      assert_equal :none, marker.name
      fallback = subject.send(:projection_hash, Read.new(
        projection: 1, state: "partial", diagnostics: [], truncated: false,
        journal_cursor: 0, journal_records: []
      ))
      assert_equal({ "attempt_id" => nil, "task_generation" => nil }, fallback.fetch("identity"))
    end
  end

  def test_missing_panels_dependencies_and_publication_observation_shapes
    with_fixture(task_class: NoPanelsTask) do |_root, task, native|
      subject = builder(task, native)
      assert_equal "unavailable", subject.send(:publication_panel).fetch("state")
      assert_equal "unavailable", subject.send(:artifact_panel).fetch("state")
      assert_equal "unavailable", subject.send(:dependency_panel, {}).fetch("state")

      subject.instance_variable_set(:@dependency_context, Object.new)
      fake_component = Object.new
      fake_component.define_singleton_method(:call) { { "state" => "current" } }
      with_replaced_singleton_method(
        Hive::TaskWorkspace::DependencyComponent, :new, ->(**) { fake_component }
      ) do
        assert_equal "current", subject.send(:dependency_panel, {}).fetch("state")
      end

      assert_equal({}, subject.send(:git_observations, {}))
      local = {
        "local" => {
          "repository" => "github.com/acme/demo", "base_branch" => "main",
          "base_oid" => "a" * 40, "observed_base_oid" => "b" * 40,
          "branch" => "task", "head_oid" => "c" * 40
        },
        "pull_request" => { "number" => 42 }
      }
      assert_equal 42, subject.send(:git_observation_from_publication, local).fetch("pr_number")
      assert_equal [ "demo:task" ], subject.send(:git_observations, local).keys
    end
  end

  def test_dependency_publication_readers_with_and_without_deadlines
    with_fixture do |_root, task, native|
      project = Struct.new(:path, :repository_identity, :name).new("/tmp", "github.com/acme/demo", "demo")
      dependency_task = Struct.new(:folder, :slug).new(native.folder, "task")
      panel = {
        "local" => { "repository" => "github.com/acme/demo", "branch" => "task" },
        "pull_request" => nil
      }

      deadline_reader = lambda do |_task, _project, deadline:|
        assert_equal 4.0, deadline
        panel
      end
      subject = builder(task, native, dependency_publication_reader: deadline_reader)
      assert_equal "task", subject.send(
        :dependency_git_observation, dependency_task, project, deadline: 4.0
      ).fetch("current_branch")

      positional_reader = ->(_task, _project) { panel }
      subject = builder(task, native, dependency_publication_reader: positional_reader)
      assert_equal "task", subject.send(
        :dependency_git_observation, dependency_task, project, deadline: 4.0
      ).fetch("current_branch")

      fake_publication = Object.new
      fake_publication.define_singleton_method(:call) { panel }
      subject = builder(task, native)
      with_replaced_singleton_method(
        Hive::TaskWorkspace::Publication, :new, ->(**) { fake_publication }
      ) do
        assert_equal "task", subject.send(
          :dependency_git_observation, dependency_task, project, deadline: 4.0
        ).fetch("current_branch")
      end
    end
  end

  def test_status_decision_operator_and_action_fallbacks
    with_fixture do |_root, task, native|
      subject = builder(task, native)
      read = Read.new(
        projection: {}, state: "current", diagnostics: [], truncated: false,
        journal_cursor: 0, journal_records: []
      )

      { "unknown" => "unavailable", "partial" => "partial", "stale" => "stale" }.each do |input, expected|
        subject.instance_variable_set(:@status_availability, input)
        assert_equal expected, subject.send(:status_payload, read).fetch("freshness")
      end
      subject.instance_variable_set(:@status_availability, "fresh")
      stale_read = read.with(state: "stale")
      assert_equal "stale", subject.send(:status_payload, stale_read).fetch("state")
      partial_read = read.with(state: "partial")
      assert_equal "partial", subject.send(:status_payload, partial_read).fetch("state")
      assert_nil subject.send(:valid_time, "bad")

      task.values["action"] = "ready_execute"
      decision = subject.send(
        :decision_payload, attempts: {}, resources: {}, action_evidence_current: true,
        answerable_questions: []
      )
      assert_equal "wait", decision.fetch("posture")

      archived = builder(task, native, archive: true).send(
        :decision_payload, attempts: {}, resources: {}, action_evidence_current: true,
        answerable_questions: []
      )
      assert_equal "investigate", archived.fetch("posture")

      task.values.merge!("recovery_visible" => true, "recovery_enabled" => false)
      disabled = subject.send(
        :action_enabled, evidence_current: true, answer_evidence_current: false
      )
      assert_equal false, disabled.first
      task.values["recovery_visible"] = false
      task.values["dispatch_action"] = "execute"
      no_daemon = builder(task, native, daemon_enabled: false)
      assert_equal [ true, nil ], no_daemon.send(
        :action_enabled, evidence_current: true, answer_evidence_current: false
      )

      task.recovery_value = { "status" => "queued" }
      payload = subject.send(:operator_payload)
      assert_equal "[REDACTED:path]", payload.dig("recovery", "context", 0)

      question = Object.new
      question.define_singleton_method(:[]) { |*| raise "bad question" }
      assert_nil subject.send(:question_value, question, :n)
      task.predicate_error = true
      refute subject.send(:task_predicate, :passable?)

      compact = subject.send(
        :compact_for_workspace, "timeline",
        "state" => "current", "records" => [ { "kind" => "event" } ], "diagnostics" => []
      )
      assert_empty compact.fetch("records")
    end
  end

  def test_semantic_budget_compacts_usage_and_primary_then_stops
    with_fixture do |_root, task, native|
      subject = builder(task, native)
      values = {
        result: {
          "supporting" => [ { "content" => "supporting", "truncated" => false } ],
          "primary" => { "content" => "primary", "truncated" => false }
        },
        usage: { "groups" => [ { "stage" => "4-execute" } ] }
      }
      attempts = 0
      replacement = lambda do |**arguments|
        attempts += 1
        if attempts <= 3
          raise ArgumentError, "semantic workspace snapshot exceeds workspace_bytes limit"
        end

        Struct.new(:payload) { def to_h = payload }.new(arguments)
      end
      with_replaced_singleton_method(
        Hive::TaskWorkspace::SemanticSnapshot, :new, replacement
      ) do
        compacted = subject.send(:semantic_snapshot_with_budget, **values)
        assert_empty compacted.dig(:usage, "groups")
        assert compacted.dig(:usage, "details_truncated")
        assert_nil compacted.dig(:result, "primary", "content")
        assert compacted.dig(:result, "primary", "truncated")
      end

      always_too_large = lambda do |**|
        raise ArgumentError, "semantic workspace snapshot exceeds workspace_bytes limit"
      end
      with_replaced_singleton_method(
        Hive::TaskWorkspace::SemanticSnapshot, :new, always_too_large
      ) do
        assert_raises(ArgumentError) do
          subject.send(
            :semantic_snapshot_with_budget,
            result: {
              "supporting" => [], "primary" => { "content" => "primary" }
            },
            usage: { "groups" => [] }
          )
        end
      end
    end
  end

  def test_semantic_usage_log_and_evidence_fail_closed_at_their_boundaries
    with_fixture do |_root, task, native|
      subject = builder(task, native)
      with_replaced_singleton_method(
        Hive::TaskWorkspace::Usage, :new, ->(**) { raise IOError, "usage failed" }
      ) do
        usage = subject.send(:semantic_usage, {})
        assert_equal "unavailable", usage.fetch("coverage")
        assert_equal [ "usage" ], usage.dig("api_equivalent", "missing_dimensions")
      end

      subject.instance_variable_set(
        :@attempt_store,
        Object.new.tap { |store| store.define_singleton_method(:fetch) { |*| raise IOError } }
      )
      projection = { "identity" => { "attempt_id" => "attempt" } }
      assert_nil subject.send(:correlated_log_reference, projection)

      task.values.merge!(
        "pr_url" => "https://github.com/acme/demo/pull/1",
        "depends_on" => "task-1", "worktree_path" => native.folder
      )
      evidence = subject.send(
        :semantic_evidence,
        {
          "worktree" => true, "diff" => true, "publication" => true,
          "media" => false, "dependencies" => true,
          "supporting_artifacts" => false
        }
      )
      assert_equal "current", evidence.dig("worktree", "state")
      assert_equal "current", evidence.dig("diff", "state")
      assert_equal "current", evidence.dig("publication", "state")
      assert_equal "current", evidence.dig("dependencies", "state")

      original = File.method(:directory?)
      with_replaced_singleton_method(
        File, :directory?,
        ->(path) { path == native.folder ? raise(Errno::EACCES) : original.call(path) }
      ) do
        refute subject.send(:actual_worktree_evidence?)
      end
    end
  end

  private

  def with_fixture(task_class: Task)
    with_tmp_dir do |root|
      task_root = File.join(root, "task")
      FileUtils.mkdir_p(task_root)
      values = {
        "slug" => "task", "id" => 42, "stage" => "4-execute",
        "marker" => nil, "attrs" => {}, "observation_mtime" => "bad"
      }
      task = task_class == Task ? Task.new : task_class.new(values)
      native = Native.new(task_root, root, "task", 42)
      yield root, task, native
    end
  end

  def builder(task, native, attempt_store: nil, dependency_publication_reader: nil,
              daemon_enabled: true, archive: false)
    Hive::TaskWorkspace::Builder.new(
      task: task, native_task: native, project: "demo",
      cursor_codec: Hive::TaskWorkspace::Timeline::CursorCodec.new(secret: SECRET),
      attempt_store: attempt_store,
      dependency_publication_reader: dependency_publication_reader,
      daemon_enabled: daemon_enabled, archive: archive
    )
  end
end
