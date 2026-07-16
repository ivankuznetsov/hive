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

      calls = with_stubbed_artifacts_spawn do
        Hive::Stages::Artifacts.run!(task, {})
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

      assert_equal({ commit: nil, status: :complete }, Hive::Stages::Artifacts.run!(task, {}))
      assert_equal :complete, Hive::Markers.current(task.state_file).name
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

      result = with_env("HIVE_HOME" => File.join(dir, "home")) do
        Hive::Stages::Artifacts.run!(task, {})
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

  private

  def make_artifacts_task(dir)
    # Config.load now resolves the global provider-account registry. Tests
    # that collapse XDG homes through HIVE_HOME must provide that directory,
    # matching Config's long-standing fail-closed HIVE_HOME contract.
    FileUtils.mkdir_p(File.join(dir, "home"))
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
