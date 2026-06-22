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
      assert_equal manifest, JSON.parse(File.read(Hive::Stages::Artifacts.media_manifest_path(task)))
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original_spawn)
    end
  end

  private

  def make_artifacts_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def write_manifest(task, manifest)
    media_dir = File.join(task.folder, "media")
    FileUtils.mkdir_p(media_dir)
    File.write(File.join(media_dir, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
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
