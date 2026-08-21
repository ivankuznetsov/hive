require "test_helper"
require "json"
require "hive/config"
require "hive/markers"
require "hive/stages/artifacts"
require "hive/task"

class StagesArtifactsTest < Minitest::Test
  include HiveTestHelper

  def test_markerless_artifacts_stage_spawns_agent_and_returns_complete_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      calls = with_not_applicable_capture do
        with_stubbed_artifacts_spawn do
          Hive::Stages::Artifacts.run_legacy_capture!(task, {})
        end
      end
      result = calls.fetch(:result)

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal 1, calls.fetch(:spawns).length
      assert File.exist?(task.state_file)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_complete_artifacts_stage_is_idempotent
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      Hive::Markers.set(task.state_file, :complete)

      result = with_not_applicable_capture { Hive::Stages::Artifacts.run_legacy_capture!(task, {}) }

      assert_equal({ commit: nil, status: :complete }, result)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_complete_marker_returns_to_error_when_required_capture_is_missing
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      Hive::Markers.set(task.state_file, :complete)
      requirement = {
        "result" => "required",
        "rationale" => "Visual implementation changed",
        "task_generation" => "generation-1"
      }
      policy = Struct.new(:requirement) do
        def ensure! = requirement
        def capture_satisfied? = false
      end.new(requirement)

      replacement = ->(_task, project:, **) { policy }
      result = with_replaced_singleton_method(
        Hive::Artifacts::CapturePolicy, :for_task, replacement
      ) do
        Hive::Stages::Artifacts.run_legacy_capture!(task, {})
      end

      assert_equal({ commit: "error", status: :error }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "required_capture_missing", marker.attrs.fetch("reason")
    end
  end

  def test_required_capture_failure_keeps_stage_in_error_with_actionable_reason
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      requirement = {
        "result" => "required",
        "rationale" => "User-visible path changed: web/app/views/tasks/show.html.erb",
        "task_generation" => "generation-1"
      }
      policy = Struct.new(:requirement) do
        def ensure! = requirement
        def capture_satisfied? = false
      end.new(requirement)

      projects = []
      replacement = ->(_task, project:, **) {
        projects << project
        policy
      }
      with_replaced_singleton_method(Hive::Artifacts::CapturePolicy, :for_task, replacement) do
        calls = with_stubbed_artifacts_spawn do
          Hive::Stages::Artifacts.run_legacy_capture!(task, {})
        end

        assert_equal({ commit: "error", status: :error }, calls.fetch(:result))
        assert_equal [ File.basename(task.project_root) ], projects
        assert_equal 1, calls.fetch(:spawns).length
        assert_includes calls.dig(:spawns, 0, :prompt), "controller-owned"
        marker = Hive::Markers.current(task.state_file)
        assert_equal :error, marker.name
        assert_equal "required_capture_missing", marker.attrs.fetch("reason")
      end
    end
  end

  def test_screenote_context_reports_disconnected_expired_invalid_and_connected_states
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      store = Hive::Screenote::CredentialStore.new(path: File.join(dir, "screenote.json"))

      context = Hive::Stages::Artifacts.screenote_context({ "screenote" => { "base_url" => "https://cfg.test" } },
                                                          credential_store: store)
      refute context[:connected]
      assert_match(/not connected/, context[:reason])
      assert_equal "https://cfg.test", context[:base_url]

      store.save("access_token" => "token", "mcp_resource" => "https://screenote.test/mcp",
                 "project_id" => "proj_1", "expires_at" => "2026-06-22T12:00:00Z")
      context = Hive::Stages::Artifacts.screenote_context({}, credential_store: store,
                                                          now: Time.utc(2026, 6, 22, 12, 0, 0))
      refute context[:connected]
      assert_match(/expired/, context[:reason])

      store.save("access_token" => "token", "mcp_resource" => "https://screenote.test/mcp",
                 "expires_at" => "2027-06-22T12:00:00Z")
      context = Hive::Stages::Artifacts.screenote_context({}, credential_store: store,
                                                          now: Time.utc(2026, 6, 22, 12, 0, 0))
      refute context[:connected]
      assert_match(/no default project/, context[:reason])

      store.save("access_token" => "", "mcp_resource" => "https://screenote.test/mcp",
                 "project_id" => "proj_1", "expires_at" => "2027-06-22T12:00:00Z")
      context = Hive::Stages::Artifacts.screenote_context({}, credential_store: store,
                                                          now: Time.utc(2026, 6, 22, 12, 0, 0))
      refute context[:connected]
      assert_match(/incomplete/, context[:reason])

      File.write(store.path, "{")
      context = Hive::Stages::Artifacts.screenote_context({}, credential_store: store)
      refute context[:connected]
      assert_match(/invalid/, context[:reason])

      store.save("access_token" => "token", "mcp_resource" => "https://screenote.test/mcp",
                 "project_id" => "proj_1", "base_url" => "",
                 "expires_at" => "2027-06-22T12:00:00Z")
      context = Hive::Stages::Artifacts.screenote_context(
        { "screenote" => { "project_id" => "proj_override", "base_url" => "https://cfg.test" } },
        credential_store: store,
        now: Time.utc(2026, 6, 22, 12, 0, 0)
      )
      assert context[:connected]
      assert_equal "proj_override", context[:project_id]
      assert_equal "https://cfg.test", context[:base_url]
      refute_includes context.inspect, "Bearer"
    end
  end

  def test_screenote_context_treats_oslevel_read_failure_as_disconnected
    # CredentialStore#load only rescues JSON errors; an OS-level File.read
    # failure (EACCES/EISDIR/TOCTOU ENOENT) escapes as SystemCallError and
    # must degrade to disconnected, not hard-fail the 7-artifacts stage (A8).
    fake_store = Object.new
    fake_store.define_singleton_method(:load) { raise Errno::EACCES, "screenote.json" }

    context = Hive::Stages::Artifacts.screenote_context(
      { "screenote" => { "base_url" => "https://cfg.test" } },
      credential_store: fake_store
    )

    refute context[:connected]
    assert_match(/could not be read/, context[:reason])
    assert_equal "https://cfg.test", context[:base_url]
  end

  def test_spawn_artifacts_agent_degrades_to_no_mcp_when_config_write_fails
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      captured = {}
      original = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **kwargs|
        captured[:path] = kwargs[:mcp_config_path]
        captured[:allowed_tools] = kwargs.fetch(:allowed_tools)
        captured[:strict] = kwargs.fetch(:strict_mcp_config)
        { status: :complete }
      end

      failing = Object.new
      failing.define_singleton_method(:write!) { raise Errno::EACCES, "cache" }

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::Screenote::McpConfig, :new, ->(credential:) { failing }) do
          with_env("HIVE_HOME" => File.join(dir, "home")) do
            Hive::Stages::Artifacts.spawn_artifacts_agent(
              task,
              {},
              "collect",
              Hive::AgentProfiles.lookup(:claude),
              screenote: connected_screenote_context
            )
          end
        end
      end

      assert_match(/without Screenote upload/, err)
      assert_nil captured[:path], "a failed MCP-config write must skip injection, not crash"
      refute_includes captured.fetch(:allowed_tools), "mcp__screenote__"
      assert_equal false, captured.fetch(:strict)
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original) if original
    end
  end

  def test_spawn_artifacts_agent_degrades_to_no_mcp_when_credential_loses_a_key
    # The OTHER rescue arm: a credential that lost a required key between
    # screenote_context's check and McpConfig#payload raises Hive::ConfigError,
    # which must degrade to a no-MCP run (A8 fail-soft), not crash the stage.
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      captured = {}
      original = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **kwargs|
        captured[:path] = kwargs[:mcp_config_path]
        captured[:allowed_tools] = kwargs.fetch(:allowed_tools)
        captured[:strict] = kwargs.fetch(:strict_mcp_config)
        { status: :complete }
      end

      failing = Object.new
      failing.define_singleton_method(:write!) { raise Hive::ConfigError, "screenote credential missing access_token" }

      _out, err = capture_io do
        with_replaced_singleton_method(Hive::Screenote::McpConfig, :new, ->(credential:) { failing }) do
          with_env("HIVE_HOME" => File.join(dir, "home")) do
            Hive::Stages::Artifacts.spawn_artifacts_agent(
              task,
              {},
              "collect",
              Hive::AgentProfiles.lookup(:claude),
              screenote: connected_screenote_context
            )
          end
        end
      end

      assert_match(/without Screenote upload/, err)
      assert_nil captured[:path], "a ConfigError on write must skip injection, not crash"
      refute_includes captured.fetch(:allowed_tools), "mcp__screenote__"
      assert_equal false, captured.fetch(:strict)
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original) if original
    end
  end

  def test_screenote_context_warns_why_upload_is_unavailable_on_a_skip_path
    # The visible fail-soft: a disconnected/incomplete credential must `warn`
    # the reason at run time so an operator sees WHY no upload happened, not
    # just silently degrade.
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      store = Hive::Screenote::CredentialStore.new(path: File.join(dir, "screenote.json"))

      _out, err = capture_io do
        context = Hive::Stages::Artifacts.screenote_context({}, credential_store: store)
        refute context[:connected]
      end

      assert_match(/Screenote upload disabled for artifacts/, err)
      assert_match(/not connected/, err)
    end
  end

  def test_spawn_artifacts_agent_injects_and_removes_screenote_mcp_config_for_claude
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      screenote = connected_screenote_context
      captured = {}
      original = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **kwargs|
        path = kwargs.fetch(:mcp_config_path)
        captured[:path] = path
        captured[:mode] = File.stat(path).mode & 0o777
        captured[:payload] = JSON.parse(File.read(path))
        captured[:allowed_tools] = kwargs.fetch(:allowed_tools)
        captured[:strict] = kwargs.fetch(:strict_mcp_config)
        { status: :complete }
      end

      with_env("HIVE_HOME" => File.join(dir, "home")) do
        Hive::Stages::Artifacts.spawn_artifacts_agent(
          task,
          {},
          "collect",
          Hive::AgentProfiles.lookup(:claude),
          screenote: screenote
        )
      end

      refute File.exist?(captured.fetch(:path)), "ephemeral MCP config must be removed after the spawn"
      refute_match(%r{\A#{Regexp.escape(task.folder)}}, captured.fetch(:path))
      assert_equal 0o600, captured.fetch(:mode)
      assert_equal "Bearer access-123",
                   captured.dig(:payload, "mcpServers", "screenote", "headers", "Authorization")
      assert_includes captured.fetch(:allowed_tools), "mcp__screenote__create_screenshot_upload"
      assert_equal true, captured.fetch(:strict)
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original) if original
    end
  end

  def test_spawn_artifacts_agent_removes_screenote_mcp_config_on_claude_error
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      captured_path = nil
      original = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **kwargs|
        captured_path = kwargs.fetch(:mcp_config_path)
        raise Hive::AgentError, "boom"
      end

      with_env("HIVE_HOME" => File.join(dir, "home")) do
        assert_raises(Hive::AgentError) do
          Hive::Stages::Artifacts.spawn_artifacts_agent(
            task,
            {},
            "collect",
            Hive::AgentProfiles.lookup(:claude),
            screenote: connected_screenote_context
          )
        end
      end

      refute File.exist?(captured_path), "ephemeral MCP config must be removed after a failed spawn"
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original) if original
    end
  end

  def test_spawn_artifacts_agent_does_not_inject_mcp_when_screenote_is_disconnected
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      captured = {}
      original = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **kwargs|
        captured[:path] = kwargs[:mcp_config_path]
        captured[:allowed_tools] = kwargs.fetch(:allowed_tools)
        captured[:strict] = kwargs.fetch(:strict_mcp_config)
        { status: :complete }
      end

      Hive::Stages::Artifacts.spawn_artifacts_agent(
        task,
        {},
        "collect",
        Hive::AgentProfiles.lookup(:claude),
        screenote: { connected: false, reason: "not connected" }
      )

      assert_nil captured[:path]
      refute_includes captured.fetch(:allowed_tools), "mcp__screenote__"
      assert_equal false, captured.fetch(:strict)
    ensure
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original) if original
    end
  end

  def test_complete_agent_run_preserves_agent_written_media_manifest
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      manifest = {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          {
            "file" => "01-home.png",
            "type" => "still",
            "caption" => "Home",
            "screenote_url" => nil,
            "screenote_skipped_reason" => "Screenote is not connected; run `hive connect screenote`."
          }
        ]
      }
      original_spawn = Hive::Stages::Artifacts.method(:spawn_artifacts_agent)
      write_media_manifest = method(:write_manifest)
      Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent) do |spawn_task, _cfg, _prompt, _profile, **|
        write_media_manifest.call(spawn_task, manifest)
        Hive::Markers.set(spawn_task.state_file, :complete)
        { status: :complete }
      end

      hive_home = File.join(dir, "home")
      FileUtils.mkdir_p(hive_home)
      result = with_not_applicable_capture do
        with_env("HIVE_HOME" => hive_home) do
          Hive::Stages::Artifacts.run_legacy_capture!(task, {})
        end
      end

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal manifest, JSON.parse(File.read(media_manifest_path(task)))
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original_spawn)
    end
  end

  def test_spawn_artifacts_agent_warns_when_ephemeral_mcp_config_cleanup_fails
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      original_spawn = Hive::Stages::Base.method(:spawn_claude_with_tmux_marker!)
      Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!) do |_task, _cfg, **_kwargs|
        { status: :complete }
      end
      # The 0600 config embeds the bearer; a cleanup failure must warn (so an
      # operator can remove it) rather than crash the stage.
      rm_f_original = FileUtils.method(:rm_f)
      FileUtils.define_singleton_method(:rm_f) { |*| raise Errno::EACCES, "screenote mcp config" }

      begin
        _out, err = capture_io do
          with_env("HIVE_HOME" => File.join(dir, "home")) do
            Hive::Stages::Artifacts.spawn_artifacts_agent(
              task,
              {},
              "collect",
              Hive::AgentProfiles.lookup(:claude),
              screenote: connected_screenote_context
            )
          end
        end

        assert_match(/could not remove ephemeral Screenote MCP config/, err)
      ensure
        FileUtils.define_singleton_method(:rm_f, rm_f_original)
        Hive::Stages::Base.define_singleton_method(:spawn_claude_with_tmux_marker!, original_spawn) if original_spawn
      end
    end
  end

  def test_controller_runs_three_distinct_roles_and_only_completes_after_publication
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      paths = [ "app/checkout.rb" ]
      identity = {
        "repository" => nil, "branch" => "demo", "implementation_base" => "a" * 40,
        "merge_base" => "a" * 40, "implementation_head" => "b" * 40,
        "changed_paths" => paths,
        "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
      }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      calls = []
      published = []
      store = Object.new
      store.define_singleton_method(:accepted_for_identity?) { |_identity| false }
      store.define_singleton_method(:blocked_for_identity?) { |_identity| false }
      store.define_singleton_method(:requirement_for_identity) { |_identity| nil }
      store.define_singleton_method(:open_generation!) do |**input|
        {
          "generation" => "c" * 64, "claims" => input.fetch(:claims),
          "exclusions" => input.fetch(:exclusions), "inference" => input.fetch(:inference),
          "implementation" => input.fetch(:identity)
        }
      end
      store.define_singleton_method(:accepted?) { |generation:| false }
      store.define_singleton_method(:attempts) { |generation:| [] }
      store.define_singleton_method(:retain_candidate!) { |evidence:, **| evidence }
      store.define_singleton_method(:append_attempt!) do |**input|
        calls << [ :append, input ]
        { "attempt_id" => input.fetch(:attempt_id) }
      end
      store.define_singleton_method(:publish_current!) do |generation:, attempt_id:|
        published << [ generation, attempt_id ]
        { "generation" => generation, "attempt_id" => attempt_id }
      end

      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, task:, writable_root: nil, **|
        calls << role
        case role
        when "inference"
          {
            actor: { "context_id" => "inference-1", "agent" => "claude" },
            output: {
              "claims" => [
                {
                  "id" => "claim-flow", "statement" => "A buyer can finish checkout and see confirmation.",
                  "proof_kind" => "document", "changed_paths" => paths
                }
              ],
              "exclusions" => []
            }
          }
        when "producer"
          relative = Pathname.new(writable_root).relative_path_from(Pathname.new(task.folder)).to_s
          {
            actor: { "context_id" => "producer-1", "agent" => "claude" },
            output: {
              "evidence" => [
                {
                  "kind" => "document", "claims" => [ "claim-flow" ],
                  "representations" => [
                    { "path" => "#{relative}/original.md", "sha256" => "d" * 64 },
                    { "path" => "#{relative}/review.txt", "sha256" => "e" * 64 }
                  ]
                }
              ]
            }
          }
        when "reviewer"
          {
            actor: { "context_id" => "reviewer-1", "agent" => "claude" },
            output: {
              "verdicts" => [
                {
                  "target_id" => "claim-flow", "verdict" => "accepted",
                  "reason" => "The retained document directly proves the checkout outcome."
                }
              ]
            }
          }
        end
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store
      )

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal %w[inference producer reviewer], calls.grep(String)
      appended = calls.find { |kind,| kind == :append }.last
      assert_equal [ "d" * 64, "e" * 64 ],
                   appended.dig(:review, "review_scope_hashes")
      assert_equal 1, published.length
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_reviewer_preflight_requires_actual_temporal_video_capability
    claims = [ { "proof_kind" => "video" } ]
    cfg = {
      "artifacts" => {
        "evidence" => {
          "reviewer" => {
            "capabilities" => {
              "proof_kinds" => %w[video], "temporal_video" => false
            }
          }
        }
      }
    }

    error = assert_raises(Hive::ConfigError) do
      Hive::Stages::Artifacts.preflight_reviewer!(cfg, claims)
    end
    assert_match(/retained temporal video/, error.message)
  end

  def test_invalid_inference_gets_one_fresh_bounded_repair_before_opening_generation
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      opens = []
      store = Object.new
      store.define_singleton_method(:open_generation!) do |**input|
        opens << input
        { "generation" => "c" * 64 }
      end
      calls = []
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, prompt:, **|
        calls << prompt
        number = calls.length
        statement = number == 1 ? "Works as expected." :
          "A buyer can finish checkout and see confirmation."
        {
          actor: { "context_id" => "inference-#{number}", "agent" => "claude" },
          output: {
            "claims" => [
              {
                "id" => "claim-flow", "statement" => statement,
                "proof_kind" => "document", "changed_paths" => [ "app/checkout.rb" ]
              }
            ],
            "exclusions" => []
          }
        }
      end

      requirement = Hive::Stages::Artifacts.infer_requirement!(
        task: task, cfg: {}, identity: identity, store: store, review_context: {}
      )

      assert_equal "c" * 64, requirement.fetch("generation")
      assert_equal 2, calls.length
      assert_includes calls.last, "claim statement must be a meaningful bounded explanation"
      assert_equal 1, opens.length
      assert_equal "inference-2", opens.first.dig(:inference, "context_id")
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_malformed_inference_gets_one_fresh_bounded_repair
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      prompts = []
      store = Object.new
      store.define_singleton_method(:open_generation!) do |**input|
        { "generation" => "c" * 64, "inference" => input.fetch(:inference) }
      end
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |prompt:, **|
        prompts << prompt
        if prompts.length == 1
          raise Hive::Stages::Artifacts::RoleOutputError,
                "inference output is invalid JSON: unexpected character: 'All' at line 1 column 1"
        end

        {
          actor: { "context_id" => "inference-2", "agent" => "pi" },
          output: {
            "claims" => [
              {
                "id" => "claim-flow",
                "statement" => "A buyer can finish checkout and see confirmation.",
                "proof_kind" => "document", "changed_paths" => [ "app/checkout.rb" ]
              }
            ],
            "exclusions" => []
          }
        }
      end

      requirement = Hive::Stages::Artifacts.infer_requirement!(
        task: task, cfg: {}, identity: identity, store: store, review_context: {}
      )

      assert_equal "c" * 64, requirement.fetch("generation")
      assert_equal 2, prompts.length
      assert_includes prompts.last, "inference output is invalid JSON"
      assert_includes prompts.last, '"previous_output": null'
      assert_equal "inference-2", requirement.dig("inference", "context_id")
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_empty_reviewer_output_gets_one_fresh_bounded_retry
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      prompts = []
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |prompt:, **|
        prompts << prompt
        if prompts.length == 1
          raise Hive::Stages::Artifacts::RoleOutputError,
                "reviewer output is missing or oversized"
        end

        {
          actor: { "context_id" => "reviewer-2", "agent" => "pi" },
          output: {
            "verdicts" => [
              {
                "target_id" => "claim-flow", "verdict" => "accepted",
                "reason" => "The retained document proves the requested flow."
              }
            ]
          }
        }
      end

      reviewer = Hive::Stages::Artifacts.run_reviewer!(
        task: task, cfg: {}, identity: outcome_identity,
        requirement: { "claims" => [], "exclusions" => [] }, evidence: [],
        review_context: {}
      )

      assert_equal "reviewer-2", reviewer.dig(:actor, "context_id")
      assert_equal 2, prompts.length
      assert_includes prompts.last, "reviewer output is missing or oversized"
      assert_includes prompts.last, "return the verdict JSON immediately"
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_overlong_verdict_reason_gets_one_repair_round_before_the_append
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      prompts = []
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |prompt:, **|
        prompts << prompt
        # 1920 bytes, over the contract's 1024-byte statement cap. Without
        # in-loop validation this only fails inside append_attempt!, which
        # runs after run_reviewer! returns — so the reviewer never gets told.
        reason = if prompts.length == 1
          "The retained document proves the requested flow. " * 40
        else
          "The retained document proves the requested flow."
        end

        {
          actor: { "context_id" => "reviewer-#{prompts.length}", "agent" => "pi" },
          output: {
            "verdicts" => [
              { "target_id" => "claim-flow", "verdict" => "accepted", "reason" => reason }
            ]
          }
        }
      end

      reviewer = Hive::Stages::Artifacts.run_reviewer!(
        task: task, cfg: {}, identity: outcome_identity,
        requirement: { "claims" => [], "exclusions" => [] }, evidence: [],
        review_context: {}
      )

      assert_equal "reviewer-2", reviewer.dig(:actor, "context_id")
      assert_equal 2, prompts.length
      assert_includes prompts.last,
                      "review verdict reason must be a meaningful bounded explanation"
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_retained_pending_candidate_skips_producer_and_resumes_review
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      generation = "c" * 64
      evidence = [
        {
          "kind" => "document", "summary" => "The retained document proves the flow.",
          "claims" => [ "claim-flow" ],
          "representations" => [
            { "sha256" => "d" * 64 }, { "sha256" => "e" * 64 }
          ]
        }
      ]
      requirement = {
        "generation" => generation,
        "claims" => [
          {
            "id" => "claim-flow", "proof_kind" => "document",
            "statement" => "A buyer can finish checkout and see confirmation.",
            "changed_paths" => [ "app/checkout.rb" ]
          }
        ],
        "exclusions" => [],
        "inference" => { "context_id" => "inference-1", "agent" => "pi" }
      }
      appended = nil
      store = Object.new
      store.define_singleton_method(:accepted_for_identity?) { |_| false }
      store.define_singleton_method(:blocked_for_identity?) { |_| false }
      store.define_singleton_method(:requirement_for_identity) { |_| requirement }
      store.define_singleton_method(:accepted?) { |generation:| false }
      store.define_singleton_method(:attempts) { |generation:| [] }
      store.define_singleton_method(:pending_candidate) do |generation:|
        {
          "attempt_id" => "attempt-resume",
          "producer" => { "context_id" => "producer-1", "agent" => "pi" },
          "evidence" => evidence
        }
      end
      store.define_singleton_method(:append_attempt!) do |**input|
        appended = input
        { "attempt_id" => input.fetch(:attempt_id), "status" => input.fetch(:status) }
      end
      store.define_singleton_method(:publish_current!) do |generation:, attempt_id:|
        { "generation" => generation, "attempt_id" => attempt_id }
      end

      roles = []
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, **|
        roles << role
        {
          actor: { "context_id" => "reviewer-1", "agent" => "pi" },
          output: {
            "verdicts" => [
              {
                "target_id" => "claim-flow", "verdict" => "accepted",
                "reason" => "The retained document proves the requested checkout flow."
              }
            ]
          }
        }
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store
      )

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal [ "reviewer" ], roles
      assert_equal "attempt-resume", appended.fetch(:attempt_id)
      assert_equal evidence, appended.fetch(:evidence)
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_targeted_recapture_preserves_accepted_hashes_and_reviews_the_full_package
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      paths = %w[app/checkout.rb app/receipt.rb]
      identity = {
        "repository" => nil, "branch" => "demo", "implementation_base" => "a" * 40,
        "merge_base" => "a" * 40, "implementation_head" => "b" * 40,
        "changed_paths" => paths,
        "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
      }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      attempts = []
      store = Object.new
      store.define_singleton_method(:accepted_for_identity?) { |_identity| false }
      store.define_singleton_method(:blocked_for_identity?) { |_identity| false }
      store.define_singleton_method(:requirement_for_identity) { |_identity| nil }
      store.define_singleton_method(:open_generation!) do |**input|
        {
          "generation" => "c" * 64, "claims" => input.fetch(:claims),
          "exclusions" => input.fetch(:exclusions), "inference" => input.fetch(:inference),
          "implementation" => input.fetch(:identity)
        }
      end
      store.define_singleton_method(:accepted?) { |generation:| false }
      store.define_singleton_method(:attempts) { |generation:| attempts }
      store.define_singleton_method(:retain_candidate!) { |evidence:, **| evidence }
      store.define_singleton_method(:append_attempt!) do |**input|
        document = input.transform_keys(&:to_s).merge("attempt_id" => input.fetch(:attempt_id))
        attempts << document
        document
      end
      published = []
      store.define_singleton_method(:publish_current!) do |generation:, attempt_id:|
        published << [ generation, attempt_id ]
        { "generation" => generation, "attempt_id" => attempt_id }
      end

      role_counts = Hash.new(0)
      producer_prompts = []
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, task:, prompt:, writable_root: nil, **|
        role_counts[role] += 1
        case role
        when "inference"
          {
            actor: { "context_id" => "inference-1", "agent" => "claude" },
            output: {
              "claims" => [
                {
                  "id" => "claim-flow", "statement" => "A buyer can finish checkout and see confirmation.",
                  "proof_kind" => "document", "changed_paths" => [ paths.first ]
                },
                {
                  "id" => "claim-receipt", "statement" => "The receipt preserves the completed order details.",
                  "proof_kind" => "document", "changed_paths" => [ paths.last ]
                }
              ],
              "exclusions" => []
            }
          }
        when "producer"
          producer_prompts << prompt
          relative = Pathname.new(writable_root).relative_path_from(Pathname.new(task.folder)).to_s
          if role_counts[role] == 1
            evidence = [
              StagesArtifactsTest.evidence_descriptor(relative, "claim-flow", "a"),
              StagesArtifactsTest.evidence_descriptor(relative, "claim-receipt", "b")
            ]
          else
            evidence = [ StagesArtifactsTest.evidence_descriptor(relative, "claim-flow", "c") ]
          end
          {
            actor: { "context_id" => "producer-#{role_counts[role]}", "agent" => "claude" },
            output: { "evidence" => evidence }
          }
        when "reviewer"
          verdicts = if role_counts[role] == 1
            [
              {
                "target_id" => "claim-flow", "verdict" => "revise",
                "reason" => "The first document omits the final confirmation state."
              },
              {
                "target_id" => "claim-receipt", "verdict" => "accepted",
                "reason" => "The retained receipt document clearly shows the completed order details."
              }
            ]
          else
            %w[claim-flow claim-receipt].map do |id|
              {
                "target_id" => id, "verdict" => "accepted",
                "reason" => "The complete retained package now demonstrates this outcome directly."
              }
            end
          end
          {
            actor: { "context_id" => "reviewer-#{role_counts[role]}", "agent" => "claude" },
            output: { "verdicts" => verdicts }
          }
        end
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store
      )

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal 2, role_counts.fetch("producer")
      assert_equal 2, role_counts.fetch("reviewer")
      assert_equal %w[accepted revise].sort, attempts.map { |attempt| attempt.fetch("status") }.sort
      second = attempts.last.fetch("evidence")
      preserved = second.find { |entry| entry.fetch("claims") == [ "claim-receipt" ] }
      assert preserved
      assert_equal "b" * 64, preserved.dig("representations", 0, "sha256")
      assert_includes producer_prompts.last, "claim-flow"
      assert_includes producer_prompts.last, "omits the final confirmation state"
      assert_equal 1, published.length
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_producer_source_mutation_is_rejected_even_after_a_successful_process_exit
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      source = File.join(dir, "worktree")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "app.rb"), "before\n")
      task.define_singleton_method(:worktree_path) { source }
      identity = { "implementation_head" => "a" * 40 }
      changed = { "implementation_head" => "b" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(changed)
      isolated = nil
      spawn = lambda do |_task, **kwargs|
        isolated = kwargs[:isolate_environment]
        kwargs.fetch(:agent_custody).call do
          File.write(File.join(source, "app.rb"), "mutated\n")
          { status: :ok, final_message: '{"evidence":[]}' }
        end
      end

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new,
        ->(**_kwargs) { resolver }
      ) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
            Hive::Stages::Artifacts.run_role!(
              role: "producer", task: task, cfg: {}, prompt: "produce",
              identity: identity, writable_root: File.join(task.folder, "evidence")
            )
          end
          assert_match(/changed the frozen implementation source/, error.message)
          assert_equal true, isolated
        end
      end
    end
  end

  def test_role_receipt_uses_provider_defaults_when_no_model_route_is_configured
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :ok, final_message: '{"claims":[],"exclusions":[]}',
            final_message_truncated: false
          }
        end
      end

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new,
        ->(**_kwargs) { resolver }
      ) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          result = Hive::Stages::Artifacts.run_role!(
            role: "inference", task: task, cfg: {}, prompt: "infer",
            identity: identity
          )

          assert_equal "provider-default", result.dig(:actor, "model")
          assert_equal "default", result.dig(:actor, "effort")
        end
      end
    end
  end

  def test_role_inherits_stage_local_model_when_it_uses_the_stage_agent
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      captured = nil
      spawn = lambda do |_task, agent_custody:, **kwargs|
        captured = kwargs
        agent_custody.call do
          {
            status: :ok, final_message: '{"claims":[],"exclusions":[]}',
            final_message_truncated: false
          }
        end
      end
      cfg = {
        "artifacts" => {
          "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "xhigh",
          "evidence" => { "inference" => { "permissions" => "read-only" } }
        }
      }

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new, ->(**) { resolver }
      ) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          result = Hive::Stages::Artifacts.run_role!(
            role: "inference", task: task, cfg: cfg, prompt: "infer", identity: identity
          )

          assert_equal "gpt-5.6-sol", captured.fetch(:model)
          assert_equal "xhigh", captured.fetch(:effort)
          assert_equal "gpt-5.6-sol", result.dig(:actor, "model")
          assert_equal "xhigh", result.dig(:actor, "effort")
        end
      end
    end
  end

  def test_role_agent_override_does_not_inherit_an_incompatible_stage_model
    cfg = {
      "artifacts" => {
        "agent" => "pi", "model" => "openrouter/deepseek/deepseek-v4-pro:xhigh",
        "effort" => "xhigh"
      }
    }

    launch = Hive::Stages::Artifacts.evidence_role_launch_config(
      cfg, { "agent" => "codex" }
    )

    assert_equal({}, launch)
  end

  def test_role_custody_excludes_controller_session_activity_from_the_agent_interval
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      journal = File.join(task.folder, "task-journal.jsonl")
      projection = File.join(task.folder, "task-projection.json")
      spawn = lambda do |_task, agent_custody:, **|
        File.write(journal, "controller session start\n")
        File.write(projection, "controller session start\n")
        result = agent_custody.call do
          { status: :ok, final_message: '{"claims":[],"exclusions":[]}' }
        end
        File.open(journal, "ab") { |file| file.write("controller session finish\n") }
        File.write(projection, "controller session finish\n")
        result
      end

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new,
        ->(**_kwargs) { resolver }
      ) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          result = Hive::Stages::Artifacts.run_role!(
            role: "inference", task: task, cfg: {}, prompt: "infer",
            identity: identity
          )

          assert_equal [], result.dig(:output, "claims")
          assert_equal "controller session start\ncontroller session finish\n",
                       File.binread(journal)
          assert_equal "controller session finish\n", File.binread(projection)
        end
      end
    end
  end

  def test_explicit_durable_route_is_reported_as_the_actual_role_actor
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      context = Hive::Attempts::Context.send(
        :new,
        attempt_id: "attempt-routed", task_generation: 1,
        routing: {
          "mode" => "explicit", "decision" => {},
          "route" => {
            "adapter" => "codex", "launch_binding_id" => "codex-default",
            "provider_account_id" => "codex-account", "model" => "gpt-5.6",
            "effort" => "high"
          },
          "circuit_generations" => [], "probe_bindings" => []
        }
      )
      captured = nil
      spawn = lambda do |_task, **kwargs|
        captured = kwargs
        kwargs.fetch(:agent_custody).call do
          { status: :ok, final_message: '{"claims":[],"exclusions":[]}' }
        end
      end
      cfg = {
        "artifacts" => {
          "evidence" => {
            "inference" => { "agent" => "claude", "model" => "claude-opus-4-1" }
          }
        }
      }

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(
          Hive::Artifacts::OutcomeEvidence::Identity, :new, ->(**) { resolver }
        ) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
            result = Hive::Stages::Artifacts.run_role!(
              role: "inference", task: task, cfg: cfg, prompt: "infer", identity: identity
            )
            assert_equal "codex", result.dig(:actor, "agent")
            assert_equal "gpt-5.6", result.dig(:actor, "model")
            assert_equal "high", result.dig(:actor, "effort")
            assert_nil captured.fetch(:routing_arguments)
          end
        end
      end
    end
  end

  def test_symlinked_producer_evidence_is_rejected_before_reviewer_launch
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      paths = [ "app/checkout.rb" ]
      identity = {
        "repository" => nil, "branch" => "demo",
        "implementation_base" => "a" * 40, "merge_base" => "a" * 40,
        "implementation_head" => "b" * 40, "changed_paths" => paths,
        "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
      }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      store = Hive::Artifacts::OutcomeEvidence::Store.new(
        task: task, project: File.basename(task.project_root),
        controller_binding: -> { { "task_generation" => "1", "recovery_epoch" => 0 } }
      )
      store.define_singleton_method(:materialize_review_context!) { |**| {} }
      reviewer_launched = false
      producer_root = nil
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, writable_root: nil, **|
        case role
        when "inference"
          {
            actor: { "context_id" => "inference-1", "agent" => "claude" },
            output: {
              "claims" => [
                {
                  "id" => "claim-flow",
                  "statement" => "A buyer finishes checkout and sees confirmation.",
                  "proof_kind" => "document", "changed_paths" => paths
                }
              ],
              "exclusions" => []
            }
          }
        when "producer"
          producer_root = writable_root
          FileUtils.mkdir_p(writable_root)
          target = File.join(writable_root, "target.md")
          link = File.join(writable_root, "original.md")
          review = File.join(writable_root, "review.txt")
          File.write(target, "# Checkout\n\nConfirmation is visible.\n")
          File.symlink(target, link)
          File.write(review, "Checkout confirmation is visible.\n")
          relative = ->(path) { Pathname.new(path).relative_path_from(Pathname.new(task.folder)).to_s }
          representation = lambda do |path, role_name, media_type|
            {
              "role" => role_name, "media_type" => media_type,
              "path" => relative.call(path), "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest
            }
          end
          {
            actor: { "context_id" => "producer-1", "agent" => "claude" },
            output: {
              "evidence" => [
                {
                  "kind" => "document", "summary" => "Checkout confirmation proof",
                  "claims" => [ "claim-flow" ],
                  "source" => {
                    "type" => "task", "name" => "artifact-agent",
                    "source_sha" => identity.fetch("implementation_head")
                  },
                  "representations" => [
                    representation.call(link, "original", "text/markdown"),
                    representation.call(review, "review", "text/plain")
                  ]
                }
              ]
            }
          }
        when "reviewer"
          reviewer_launched = true
          flunk "reviewer must not receive unadmitted producer evidence"
        end
      end

      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.run_outcome_evidence!(
          task, {}, identity_resolver: resolver, store: store
        )
      end
      assert_match(/regular file/, error.message)
      refute reviewer_launched
      refute File.exist?(producer_root)
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_producer_permissions_are_controller_scoped_to_the_evidence_root
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      source = File.join(dir, "worktree")
      evidence = File.join(task.folder, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p([ source, evidence ])
      task.define_singleton_method(:worktree_path) { source }

      kwargs = Hive::Stages::Artifacts.role_security_kwargs(
        "producer", task: task, cfg: {}, profile: Hive::AgentProfiles.lookup(:claude),
        actor_cfg: {}, writable_root: evidence
      )

      assert_equal "dontAsk", kwargs.fetch(:permission_mode)
      edit_rule = Array(kwargs.fetch(:allowed_tools)).find { |rule| rule.start_with?("Edit(") }
      assert_includes edit_rule, File.expand_path(evidence)
      assert_includes kwargs.fetch(:disallowed_tools), "Bash"
      refute_includes edit_rule, File.expand_path(source)
    end
  end

  def test_workspace_producer_can_run_the_controller_issued_browser_cli
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      evidence = File.join(task.folder, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p(evidence)
      codex = Hive::AgentProfiles.lookup(:codex)

      assert Hive::Stages::Artifacts.preflight_producer!(
        { "artifacts" => { "evidence" => { "producer" => { "agent" => "codex" } } } },
        [ { "proof_kind" => "video" } ]
      )
      kwargs = Hive::Stages::Artifacts.role_security_kwargs(
        "producer", task: task, cfg: {}, profile: codex,
        actor_cfg: { "agent" => "codex" }, writable_root: evidence
      )
      assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                   kwargs.fetch(:permission_mode)

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.preflight_producer!(
          {}, [ { "proof_kind" => "screenshot" } ]
        )
      end
      assert_match(/managed agent-browser capture boundary/, error.message)
    end
  end

  def test_pi_producer_uses_the_controller_compiled_evidence_runtime
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      evidence = File.join(task.folder, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p(evidence)
      pi = Hive::AgentProfiles.lookup(:pi)
      policy = Struct.new(
        :permission_mode, :allowed_tools, :disallowed_tools, :directories,
        keyword_init: true
      ).new(
        permission_mode: nil, allowed_tools: %w[Read LS Grep Glob],
        disallowed_tools: %w[Bash Write Edit], directories: [ task.folder ]
      )

      assert_equal pi, Hive::Stages::Artifacts.preflight_producer!(
        { "artifacts" => { "evidence" => { "producer" => { "agent" => "pi" } } } },
        [ { "proof_kind" => "terminal" } ]
      )
      kwargs = Hive::Stages::Artifacts.role_security_kwargs(
        "producer", task: task, cfg: {}, profile: pi,
        actor_cfg: { "agent" => "pi" }, writable_root: evidence,
        producer_runtime_policy: policy
      )

      assert_same policy, kwargs.fetch(:runtime_policy)
      assert_equal %w[Read LS Grep Glob], kwargs.fetch(:allowed_tools)
      assert_includes kwargs.fetch(:disallowed_tools), "Bash"
      assert_includes kwargs.fetch(:disallowed_tools), "Write"
    end
  end

  def test_run_touches_state_and_translates_controller_errors_to_a_durable_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      FileUtils.rm_f(task.state_file)
      replacement = ->(_task, _cfg) { { commit: "done", status: :complete } }
      result = with_replaced_singleton_method(
        Hive::Stages::Artifacts, :run_outcome_evidence!, replacement
      ) do
        Hive::Stages::Artifacts.run!(task, nil)
      end
      assert_equal({ commit: "done", status: :complete }, result)
      assert File.exist?(task.state_file)

      replacement = lambda do |_task, _cfg|
        raise Hive::Artifacts::OutcomeEvidence::StoreError, "contradictory evidence"
      end
      result = with_replaced_singleton_method(
        Hive::Stages::Artifacts, :run_outcome_evidence!, replacement
      ) do
        Hive::Stages::Artifacts.run!(task, {})
      end
      assert_equal({ commit: "error", status: :error }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "outcome_evidence_invalid", marker.attrs.fetch("reason")
    end
  end

  def test_run_preserves_role_provider_limits_as_a_cooldown_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      retry_at = "2026-08-21T10:15:00Z"
      failure = Hive::Stages::Artifacts::RoleAgentError.new(
        role: "inference",
        profile: Struct.new(:name).new(:pi),
        result: {
          status: :error,
          error_reason: "limits_reached",
          error_message: "limits reached for pi: Prompt tokens limit exceeded",
          limit_text: "Prompt tokens limit exceeded: 48014 > 46973",
          retry_at: retry_at,
          provider_error: { provider: :pi, status_code: 402 }
        }
      )
      replacement = ->(_task, _cfg) { raise failure }

      result = with_replaced_singleton_method(
        Hive::Stages::Artifacts, :run_outcome_evidence!, replacement
      ) do
        Hive::Stages::Artifacts.run!(task, {})
      end

      assert_equal({ commit: "limits_reached", status: :error }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      assert_equal "pi", marker.attrs.fetch("provider")
      assert_equal retry_at, marker.attrs.fetch("retry_after")
      assert_includes marker.attrs.fetch("message"), "Prompt tokens limit exceeded"
    end
  end

  def test_run_preserves_non_limit_role_provider_errors
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      failure = Hive::Stages::Artifacts::RoleAgentError.new(
        role: "reviewer",
        profile: Struct.new(:name).new(:pi),
        result: {
          status: :error,
          error_reason: "provider_error",
          error_message: "upstream refused the request",
          provider_error: { provider: :pi, status_code: 503 }
        }
      )
      replacement = ->(_task, _cfg) { raise failure }

      result = with_replaced_singleton_method(
        Hive::Stages::Artifacts, :run_outcome_evidence!, replacement
      ) do
        Hive::Stages::Artifacts.run!(task, {})
      end

      assert_equal({ commit: "error", status: :error }, result)
      marker = Hive::Markers.current(task.state_file)
      assert_equal "provider_error", marker.attrs.fetch("reason")
      assert_equal "pi", marker.attrs.fetch("provider")
      assert_equal "503", marker.attrs.fetch("status_code")
      assert_equal "upstream refused the request", marker.attrs.fetch("message")
    end
  end

  def test_controller_replays_accepted_blocked_capability_and_attempt_terminal_states
    scenarios = %i[accepted_identity blocked_identity accepted_generation accepted_attempt capability]
    scenarios.each do |scenario|
      Dir.mktmpdir("hive-artifacts-stage") do |dir|
        task = make_artifacts_task(dir)
        identity = outcome_identity
        resolver = Struct.new(:value) { def resolve = value }.new(identity)
        requirement = outcome_requirement(identity)
        pointer = if scenario == :blocked_identity || scenario == :capability
          blocked_pointer(requirement.fetch("generation"))
        else
          accepted_pointer(requirement.fetch("generation"))
        end
        accepted_attempt = {
          "attempt_id" => "attempt-accepted", "status" => "accepted"
        }
        store = Object.new
        store.define_singleton_method(:accepted_for_identity?) { |_value| scenario == :accepted_identity }
        store.define_singleton_method(:blocked_for_identity?) { |_value| scenario == :blocked_identity }
        store.define_singleton_method(:current) { pointer }
        store.define_singleton_method(:requirement_for_identity) { |_value| requirement }
        store.define_singleton_method(:accepted?) do |generation:|
          scenario == :accepted_generation
        end
        store.define_singleton_method(:attempts) do |generation:|
          scenario == :accepted_attempt ? [ accepted_attempt ] : []
        end
        store.define_singleton_method(:publish_current!) do |generation:, attempt_id:|
          pointer
        end
        store.define_singleton_method(:publish_blocked!) do |**|
          pointer
        end
        cfg = if scenario == :capability
          {
            "artifacts" => {
              "evidence" => {
                "reviewer" => {
                  "capabilities" => {
                    "proof_kinds" => %w[document], "temporal_video" => true
                  }
                }
              }
            }
          }
        else
          {}
        end
        requirement["claims"].first["proof_kind"] = "screenshot" if scenario == :capability

        result = Hive::Stages::Artifacts.run_outcome_evidence!(
          task, cfg, identity_resolver: resolver, store: store
        )

        expected = %i[blocked_identity capability].include?(scenario) ? :error : :complete
        assert_equal expected, result.fetch(:status), scenario
        assert_equal(expected == :error ? :error : :complete,
                     Hive::Markers.current(task.state_file).name, scenario)
      end
    end
  end

  def test_controller_blocks_prior_blocked_unrecapturable_and_exhausted_reviews
    scenarios = {
      blocked: {
        "status" => "blocked",
        "review" => {
          "verdicts" => [
            {
              "target_id" => "claim-flow", "verdict" => "blocked",
              "reason" => "The environment cannot render the required state safely."
            }
          ]
        }
      },
      unrecapturable: {
        "status" => "revise",
        "review" => {
          "verdicts" => [
            {
              "target_id" => "excluded-target", "verdict" => "revise",
              "reason" => "The exclusion needs semantic clarification before acceptance."
            }
          ]
        }
      },
      exhausted: {
        "status" => "revise",
        "review" => {
          "verdicts" => [
            {
              "target_id" => "claim-flow", "verdict" => "revise",
              "reason" => "The document needs one clearer bounded outcome statement."
            }
          ]
        }
      }
    }
    scenarios.each do |name, attempt|
      Dir.mktmpdir("hive-artifacts-stage") do |dir|
        task = make_artifacts_task(dir)
        identity = outcome_identity
        resolver = Struct.new(:value) { def resolve = value }.new(identity)
        requirement = outcome_requirement(identity)
        attempt = plain_hash(attempt).merge("attempt_id" => "attempt-1")
        published = []
        store = terminal_store(requirement, [ attempt ], published)
        cfg = name == :exhausted ? {
          "artifacts" => { "evidence" => { "max_recaptures" => 0 } }
        } : {}

        result = Hive::Stages::Artifacts.run_outcome_evidence!(
          task, cfg, identity_resolver: resolver, store: store
        )

        assert_equal :error, result.fetch(:status), name
        assert_equal 1, published.length, name
        expected_reason = name == :exhausted ? "recaptures_exhausted" : "review_blocked"
        assert_equal expected_reason, published.first.fetch(:reason), name
      end
    end
  end

  def test_controller_publishes_a_fresh_blocked_review_attempt
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      requirement = outcome_requirement(identity)
      published = []
      store = terminal_store(requirement, [], published)
      store.define_singleton_method(:retain_candidate!) { |evidence:, **| evidence }
      store.define_singleton_method(:append_attempt!) do |**input|
        input.transform_keys(&:to_s).merge("attempt_id" => input.fetch(:attempt_id))
      end
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, task:, writable_root: nil, **|
        if role == "producer"
          relative = Pathname.new(writable_root).relative_path_from(Pathname.new(task.folder)).to_s
          {
            actor: { "context_id" => "producer-1", "agent" => "claude" },
            output: {
              "evidence" => [
                {
                  "kind" => "document", "claims" => [ "claim-flow" ],
                  "representations" => [ { "path" => "#{relative}/proof.md" } ]
                }
              ]
            }
          }
        else
          {
            actor: { "context_id" => "reviewer-1", "agent" => "claude" },
            output: {
              "verdicts" => [
                {
                  "target_id" => "claim-flow", "verdict" => "blocked",
                  "reason" => "The runtime cannot render the required bounded state."
                }
              ]
            }
          }
        end
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store
      )
      assert_equal :error, result.fetch(:status)
      assert_equal "review_blocked", published.first.fetch(:reason)
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_capture_capability_failure_publishes_a_durable_blocked_pointer
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      requirement = outcome_requirement(identity)
      published = []
      prior = {
        "attempt_id" => "attempt-01-prior", "status" => "revise",
        "evidence" => [],
        "review" => {
          "verdicts" => [
            {
              "target_id" => "claim-flow", "verdict" => "revise",
              "reason" => "The retained proof needs the final state."
            }
          ]
        }
      }
      store = terminal_store(requirement, [ prior ], published)
      store.define_singleton_method(:review_context_for_identity) do |_value|
        { "path" => "outcome-evidence/context.diff" }
      end
      toolkit = Object.new
      toolkit.define_singleton_method(:prepare!) do |**|
        raise Hive::ConfigError, "ffmpeg unavailable"
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store, capture_toolkit: toolkit
      )

      assert_equal :error, result.fetch(:status)
      assert_equal "capability_blocked", published.first.fetch(:reason)
      assert_equal [ "claim-flow" ], published.first.fetch(:failed_targets)
      assert_equal :error, Hive::Markers.current(task.state_file).name
    end
  end

  def test_initial_capture_capability_failure_names_all_required_claims
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      requirement = outcome_requirement(identity)
      published = []
      store = terminal_store(requirement, [], published)
      toolkit = Object.new
      toolkit.define_singleton_method(:prepare!) do |**|
        raise Hive::ConfigError, "capture unavailable"
      end

      result = Hive::Stages::Artifacts.run_outcome_evidence!(
        task, {}, identity_resolver: resolver, store: store, capture_toolkit: toolkit
      )
      assert_equal :error, result.fetch(:status)
      assert_equal [ "claim-flow" ], published.first.fetch(:failed_targets)
    end
  end

  def test_reviewer_output_rejects_extra_top_level_authority
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = outcome_identity
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      requirement = outcome_requirement(identity)
      store = terminal_store(requirement, [], [])
      store.define_singleton_method(:retain_candidate!) { |evidence:, **| evidence }
      original = Hive::Stages::Artifacts.method(:run_role!)
      Hive::Stages::Artifacts.define_singleton_method(:run_role!) do |role:, task:, writable_root: nil, **|
        if role == "producer"
          relative = Pathname.new(writable_root).relative_path_from(Pathname.new(task.folder)).to_s
          {
            actor: { "context_id" => "producer-1", "agent" => "claude" },
            output: {
              "evidence" => [
                {
                  "kind" => "document", "claims" => [ "claim-flow" ],
                  "representations" => [ { "path" => "#{relative}/proof.md" } ]
                }
              ]
            }
          }
        else
          {
            actor: { "context_id" => "reviewer-1", "agent" => "claude" },
            output: { "verdicts" => [], "extra" => true }
          }
        end
      end

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.run_outcome_evidence!(
          task, {}, identity_resolver: resolver, store: store
        )
      end
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:run_role!, original) if original
    end
  end

  def test_producer_process_cleanup_and_visual_profile_preflight_are_fail_closed
    kills = []
    with_replaced_singleton_method(Process, :kill, ->(signal, pgid) { kills << [ signal, pgid ] }) do
      Hive::Stages::Artifacts.cleanup_producer_process_group(pgid: 123)
    end
    assert_equal [ [ "TERM", -123 ], [ "KILL", -123 ] ], kills
    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
      assert_nil Hive::Stages::Artifacts.cleanup_producer_process_group(pgid: 123)
    end

    profile = Object.new
    profile.define_singleton_method(:name) { :codex }
    profile.define_singleton_method(:workspace_write_supported?) { false }
    profile.define_singleton_method(:add_dir_flag) { nil }
    with_replaced_singleton_method(Hive::Stages::Base, :stage_profile, ->(*) { profile }) do
      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.preflight_producer!(
          { "artifacts" => { "evidence" => { "producer" => { "agent" => "codex" } } } },
          [ { "proof_kind" => "video" } ]
        )
      end
    end
  end

  def test_non_claude_artifacts_spawn_and_action_mapping
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      profile = Hive::AgentProfiles.lookup(:codex)
      scope = {
        add_dirs: [], permission_mode: "workspace-write",
        allowed_tools: nil, disallowed_tools: nil
      }
      captured = nil
      with_replaced_singleton_method(
        Hive::Stages::Base, :stage_permission_scope_or_mark!, ->(*) { scope }
      ) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :model_routing_arguments, ->(*) { [] }
        ) do
          with_replaced_singleton_method(
            Hive::Stages::Base, :spawn_agent, ->(_task, **kwargs) { captured = kwargs }
          ) do
            Hive::Stages::Artifacts.spawn_artifacts_agent(
              task, {}, "prompt", profile,
              screenote: { connected: false }
            )
          end
        end
      end
      assert_equal profile, captured.fetch(:profile)
      assert_equal "error", Hive::Stages::Artifacts.action_for(:error)
      assert_equal "waiting", Hive::Stages::Artifacts.action_for(:waiting)
    end
  end

  def test_role_process_boundary_rejects_agent_firewall_status_and_truncation_failures
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new, ->(**) { resolver }
      ) do
        raising = ->(*) { raise Hive::AgentError, "provider failed" }
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, raising) do
          assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
            Hive::Stages::Artifacts.run_role!(
              role: "inference", task: task, cfg: {}, prompt: "infer", identity: identity
            )
          end
        end

        custody_missing = lambda do |_task, **|
          { status: :ok, final_message: '{"claims":[],"exclusions":[]}' }
        end
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, custody_missing) do
          error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
            Hive::Stages::Artifacts.run_role!(
              role: "inference", task: task, cfg: {}, prompt: "infer", identity: identity
            )
          end
          assert_includes error.message, "agent custody was not invoked"
        end

        report = Object.new
        report.define_singleton_method(:valid?) { false }
        report.define_singleton_method(:diagnostic) { "task.md changed" }
        spawn = lambda do |_task, agent_custody:, **|
          agent_custody.call do
            { status: :ok, final_message: '{"claims":[],"exclusions":[]}' }
          end
        end
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          with_replaced_singleton_method(
            Hive::ArtifactFirewall, :validate_and_restore, ->(*) { report }
          ) do
            assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
              Hive::Stages::Artifacts.run_role!(
                role: "inference", task: task, cfg: {}, prompt: "infer", identity: identity
              )
            end
          end
        end

        failing_spawn = lambda do |_task, agent_custody:, **|
          agent_custody.call { raise Hive::AgentError, "provider failed after tamper" }
        end
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, failing_spawn) do
          with_replaced_singleton_method(
            Hive::ArtifactFirewall, :validate_and_restore, ->(*) { report }
          ) do
            error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
              Hive::Stages::Artifacts.run_role!(
                role: "inference", task: task, cfg: {}, prompt: "infer", identity: identity
              )
            end
            assert_includes error.message, "inference modified protected task state"
            assert_includes error.message, "task.md changed"
          end
        end

        [
          [ { status: :error, final_message: "{}" }, Hive::Stages::Artifacts::RoleAgentError ],
          [
            {
              status: :ok, final_message: '{"claims":[],"exclusions":[]}',
              final_message_truncated: true
            },
            Hive::Artifacts::OutcomeEvidence::StoreError
          ]
        ].each do |result, error_class|
          with_replaced_singleton_method(
            Hive::Stages::Base, :spawn_agent, lambda { |_task, agent_custody:, **|
              agent_custody.call { result }
            }
          ) do
            assert_raises(error_class) do
              Hive::Stages::Artifacts.run_role!(
                role: "inference", task: task, cfg: {}, prompt: "infer", identity: identity
              )
            end
          end
        end
      end
    end
  end

  def test_workspace_producer_launches_only_with_controller_owned_writable_roots
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      identity = { "implementation_head" => "a" * 40 }
      resolver = Struct.new(:value) { def resolve = value }.new(identity)
      writable_root = File.join(task.folder, "outcome-evidence", "work", "generation", "attempt")
      captured = nil
      spawn = lambda do |_task, **kwargs|
        captured = kwargs
        kwargs.fetch(:agent_custody).call do
          { status: :ok, final_message: '{"evidence":[]}', final_message_truncated: false }
        end
      end
      cfg = {
        "artifacts" => { "evidence" => { "producer" => { "agent" => "codex" } } }
      }

      with_replaced_singleton_method(
        Hive::Artifacts::OutcomeEvidence::Identity, :new, ->(**) { resolver }
      ) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
      Hive::Stages::Artifacts.run_role!(
            role: "producer", task: task, cfg: cfg, prompt: "produce",
            identity: identity, writable_root: writable_root,
            producer_permission_arguments: [ "--permission-profile", "hive-evidence" ]
          )
        end
      end
      assert_equal [ writable_root ], captured.fetch(:add_dirs)
      assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                   captured.fetch(:permission_mode)
      assert_equal [ "--permission-profile", "hive-evidence" ],
                   captured.fetch(:permission_arguments)
    end
  end

  def test_role_security_preflight_semantic_and_recapture_contracts_fail_closed
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      claude = Hive::AgentProfiles.lookup(:claude)
      codex = Hive::AgentProfiles.lookup(:codex)
      no_scope = Object.new
      no_scope.define_singleton_method(:name) { :unsupported }
      no_scope.define_singleton_method(:workspace_write_supported?) { false }
      no_scope.define_singleton_method(:read_only_supported?) { false }

      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.role_security_kwargs(
          "producer", task: task, cfg: {}, profile: claude, actor_cfg: {}
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.role_security_kwargs(
          "producer", task: task, cfg: {}, profile: no_scope, actor_cfg: {},
          writable_root: File.join(task.folder, "proof")
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.role_security_kwargs(
          "inference", task: task, cfg: {}, profile: claude,
          actor_cfg: { "permissions" => "yolo" }
        )
      end
      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.role_security_kwargs(
          "reviewer", task: task, cfg: {}, profile: no_scope, actor_cfg: {}
        )
      end
      assert_equal Hive::AgentProfile::READ_ONLY_PERMISSION_MODE,
                   Hive::Stages::Artifacts.role_security_kwargs(
                     "reviewer", task: task, cfg: {}, profile: codex, actor_cfg: {}
                   ).fetch(:permission_mode)

      assert_raises(Hive::ConfigError) do
        Hive::Stages::Artifacts.preflight_reviewer!(
          {
            "artifacts" => {
              "evidence" => {
                "reviewer" => {
                  "capabilities" => {
                    "proof_kinds" => %w[document], "temporal_video" => true
                  }
                }
              }
            }
          },
          [ { "proof_kind" => "screenshot" } ]
        )
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.semantic_review_status!([])
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.merge_candidate_evidence!(
          { "evidence" => [] },
          [ { "claims" => [ "claim-other" ] } ],
          [ { "target_id" => "claim-flow" } ]
        )
      end

      merged = Hive::Stages::Artifacts.merge_candidate_evidence!(
        {
          "evidence" => [
            { "claims" => %w[claim-flow claim-receipt], "summary" => "old" }
          ]
        },
        [ { "claims" => [ "claim-flow" ], "summary" => "new" } ],
        [ { "target_id" => "claim-flow" }, { "target_id" => "claim-receipt" } ]
      )
      assert_equal [
        { "claims" => [ "claim-receipt" ], "summary" => "old" },
        { "claims" => [ "claim-flow" ], "summary" => "new" }
      ], merged
    end
  end

  def test_pi_read_only_roles_use_the_portable_runtime_sandbox
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      worktree = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree)
      task.define_singleton_method(:worktree_path) { worktree }
      profile = Hive::AgentProfiles.lookup(:pi)
      policy = Struct.new(:permission_mode, :allowed_tools, :disallowed_tools).new(
        nil, %w[Read LS Grep Glob], %w[Edit Write Bash]
      )
      captured = nil
      compile = lambda do |spec, **kwargs|
        captured = { spec: spec, **kwargs }
        policy
      end

      security = with_replaced_singleton_method(
        Hive::WorkflowPackage::RuntimePolicy, :compile_actor, compile
      ) do
        Hive::Stages::Artifacts.role_security_kwargs(
          "inference", task: task, cfg: {}, profile: profile, actor_cfg: {}
        )
      end

      assert_equal "read-only", captured.fetch(:spec)
      assert_equal worktree, captured.fetch(:task_folder)
      assert_equal task.folder, captured.fetch(:package_root)
      assert_same profile, captured.fetch(:profile)
      assert_same policy, security.fetch(:runtime_policy)
      assert_equal %w[Read LS Grep Glob], security.fetch(:allowed_tools)
      assert_equal %w[Edit Write Bash], security.fetch(:disallowed_tools)
    end
  end

  def test_role_json_producer_paths_and_cleanup_roots_are_bounded
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.parse_role_output!("", "inference")
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.parse_role_output!("{", "inference")
      end
      fenced = <<~OUTPUT
        Evidence for `./bin/verify` captured successfully.

        ```json
        {"evidence":[]}
        ```
      OUTPUT
      assert_equal(
        { "evidence" => [] },
        Hive::Stages::Artifacts.parse_role_output!(fenced, "producer")
      )
      assert_raises(Hive::Stages::Artifacts::RoleOutputError) do
        Hive::Stages::Artifacts.parse_role_output!(
          "```json\n{\"evidence\":[]}\n```\ntrailing prose", "producer"
        )
      end
      assert_raises(Hive::Stages::Artifacts::RoleOutputError) do
        Hive::Stages::Artifacts.parse_role_output!(
          "```json\n{\"evidence\":[]}\n```\n```json\n{}\n```", "producer"
        )
      end

      writable_root = File.join(task.folder, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p(writable_root)
      evidence = [
        {
          "source" => { "type" => "task" },
          "representations" => [ { "path" => "outside/proof.md" } ]
        }
      ]
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.ensure_producer_paths!(task, writable_root, evidence)
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        Hive::Stages::Artifacts.remove_producer_work!(task, task.folder)
      end

      outside = File.join(dir, "outside-proof")
      File.write(outside, "keep")
      link = File.join(writable_root, "link")
      File.symlink(outside, link)
      Hive::Stages::Artifacts.remove_producer_work!(task, link)
      refute File.exist?(link)
      assert_equal "keep", File.read(outside)
      assert_nil Hive::Stages::Artifacts.remove_producer_work!(task, link)
    end
  end

  private

  def outcome_identity
    paths = [ "app/checkout.rb" ]
    {
      "repository" => nil, "branch" => "demo",
      "implementation_base" => "a" * 40, "merge_base" => "a" * 40,
      "implementation_head" => "b" * 40, "changed_paths" => paths,
      "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
    }
  end

  def outcome_requirement(identity)
    {
      "generation" => "c" * 64, "implementation" => identity,
      "claims" => [
        {
          "id" => "claim-flow",
          "statement" => "A buyer can finish checkout and see confirmation.",
          "proof_kind" => "document", "changed_paths" => [ "app/checkout.rb" ]
        }
      ],
      "exclusions" => [],
      "inference" => { "context_id" => "inference-1", "agent" => "claude" }
    }
  end

  def accepted_pointer(generation)
    { "generation" => generation, "attempt_id" => "attempt-accepted" }
  end

  def blocked_pointer(generation)
    {
      "generation" => generation, "reason" => "capability_blocked",
      "recovery_digest" => "d" * 64, "attempt_count" => 0,
      "failed_targets" => [ "claim-flow" ]
    }
  end

  def terminal_store(requirement, attempts, published)
    store = Object.new
    store.define_singleton_method(:accepted_for_identity?) { |_value| false }
    store.define_singleton_method(:blocked_for_identity?) { |_value| false }
    store.define_singleton_method(:requirement_for_identity) { |_value| requirement }
    store.define_singleton_method(:accepted?) { |generation:| false }
    store.define_singleton_method(:attempts) { |generation:| attempts }
    store.define_singleton_method(:publish_blocked!) do |**input|
      published << input
      blocked_pointer = {
        "generation" => input.fetch(:generation), "reason" => input.fetch(:reason),
        "recovery_digest" => "d" * 64,
        "attempt_count" => input.fetch(:attempt_ids).length,
        "failed_targets" => input.fetch(:failed_targets)
      }
      blocked_pointer
    end
    store
  end

  def plain_hash(value)
    JSON.parse(JSON.generate(value), object_class: Hash)
  end

  def self.evidence_descriptor(relative, claim_id, digest_char)
    {
      "kind" => "document", "claims" => [ claim_id ],
      "representations" => [
        { "path" => "#{relative}/#{claim_id}.md", "sha256" => digest_char * 64 },
        { "path" => "#{relative}/#{claim_id}.txt", "sha256" => digest_char.next * 64 }
      ]
    }
  end

  def make_artifacts_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def media_manifest_path(task)
    File.join(task.folder, "media", "manifest.json")
  end

  def write_manifest(task, manifest)
    media_dir = File.join(task.folder, "media")
    FileUtils.mkdir_p(media_dir)
    File.write(media_manifest_path(task), "#{JSON.pretty_generate(manifest)}\n")
  end

  def with_not_applicable_capture
    receipt = {
      "result" => "not_applicable",
      "rationale" => "Test fixture has deterministic nonvisual scope.",
      "task_generation" => "test-generation"
    }
    policy = Struct.new(:receipt) do
      def ensure! = receipt
      def capture_satisfied? = true
    end.new(receipt)
    replacement = ->(_task, project:, **) { policy }
    with_replaced_singleton_method(Hive::Artifacts::CapturePolicy, :for_task, replacement) do
      yield
    end
  end

  def with_stubbed_artifacts_spawn
    original = Hive::Stages::Artifacts.method(:spawn_artifacts_agent)
    spawns = []
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent) do |task, cfg, prompt, profile, **kwargs|
      spawns << { task: task, cfg: cfg, prompt: prompt, profile: profile, kwargs: kwargs }
      Hive::Markers.set(task.state_file, :complete)
      { status: :complete }
    end

    { result: yield, spawns: spawns }
  ensure
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original)
  end

  def connected_screenote_context
    {
      connected: true,
      project_id: "proj_1",
      base_url: "https://screenote.test",
      reason: nil,
      credential: {
        "access_token" => "access-123",
        "mcp_resource" => "https://screenote.test/mcp"
      }
    }
  end
end
