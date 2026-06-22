require "fileutils"
require "hive/claude_launcher"
require "hive/markers"
require "hive/screenote/credential_store"
require "hive/screenote/mcp_config"
require "hive/screenote/oauth_client"
require "hive/stages/base"

module Hive
  module Stages
    module Artifacts
      module_function

      def run!(task, cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: :complete } if marker.name == :complete

        profile = Hive::Stages::Base.stage_profile(cfg, "artifacts")
        screenote = screenote_context(cfg)
        prompt = render_prompt(task, screenote: screenote)
        spawn_artifacts_agent(task, cfg, prompt, profile, screenote: screenote)
        marker = Hive::Markers.current(task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def spawn_artifacts_agent(task, cfg, prompt, profile, screenote: screenote_context(cfg))
        cwd = File.directory?(task.worktree_path.to_s) ? task.worktree_path : task.folder
        kwargs = {
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: cwd,
          max_budget_usd: cfg.dig("budget_usd", "artifacts") || Hive::Config::DEFAULTS.dig("budget_usd", "artifacts"),
          timeout_sec: cfg.dig("timeout_sec", "artifacts") || Hive::Config::DEFAULTS.dig("timeout_sec", "artifacts"),
          log_label: "artifacts",
          profile: profile,
          status_mode: :state_file_marker
        }
        mcp_config_path = nil
        if profile.name == :claude
          allowed_tools = Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
          if screenote[:connected]
            begin
              mcp_config_path = Hive::Screenote::McpConfig.new(credential: screenote.fetch(:credential)).write!
              allowed_tools = Hive::Screenote::McpConfig.allowed_tools_csv(allowed_tools)
            rescue SystemCallError => e
              # An unwritable/full cache_home must degrade to a no-MCP run
              # (the agent keeps local media), not hard-fail the stage (A8).
              warn "[hive] could not write Screenote MCP config; running artifacts " \
                   "without Screenote upload: #{e.message}"
              mcp_config_path = nil
            end
          end
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("7-artifacts", task),
            allowed_tools: allowed_tools,
            mcp_config_path: mcp_config_path,
            strict_mcp_config: !mcp_config_path.nil?
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
      ensure
        FileUtils.rm_f(mcp_config_path) if mcp_config_path
      end

      def render_prompt(task, screenote: nil)
        screenote ||= disconnected("Screenote is not connected; run `hive connect screenote`.", {})
        Hive::Stages::Base.render(
          "artifacts_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: task.worktree_path,
            artifact_file: task.state_file,
            screenote_connected: screenote[:connected],
            screenote_project_id: screenote[:project_id],
            screenote_base_url: screenote[:base_url],
            screenote_skip_reason: screenote[:reason],
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def screenote_context(cfg, credential_store: Hive::Screenote::CredentialStore.new, now: Time.now)
        credential = credential_store.load
        return disconnected("Screenote is not connected; run `hive connect screenote`.", cfg) unless credential

        if credential_store.expired?(credential, now: now)
          return disconnected("Screenote OAuth token expired; run `hive connect screenote`.", cfg)
        end

        project_id = cfg.dig("screenote", "project_id").to_s.strip
        project_id = credential["project_id"].to_s.strip if project_id.empty?
        return disconnected("Screenote has no default project; run `hive connect screenote`.", cfg) if project_id.empty?

        if credential["access_token"].to_s.strip.empty? || credential["mcp_resource"].to_s.strip.empty?
          return disconnected("Screenote credential is incomplete; run `hive connect screenote`.", cfg)
        end

        {
          connected: true,
          credential: credential,
          project_id: project_id,
          base_url: connected_base_url(credential, cfg),
          reason: nil
        }
      rescue Hive::ConfigError => e
        disconnected("Screenote credential is invalid: #{e.message}", cfg)
      rescue SystemCallError => e
        # A8 fail-soft: a read failure on the credential file (EACCES /
        # EISDIR / a TOCTOU ENOENT) must skip Screenote, not hard-fail the
        # 7-artifacts stage. CredentialStore#load only rescues JSON errors,
        # so an OS-level File.read failure escapes here as SystemCallError.
        disconnected("Screenote credential could not be read: #{e.message}", cfg)
      end

      def disconnected(reason, cfg)
        {
          connected: false,
          credential: nil,
          project_id: nil,
          base_url: config_base_url(cfg),
          reason: reason
        }
      end

      # The configured Screenote base URL, falling back to the OAuth
      # client's default. The `|| DEFAULT_BASE_URL` fallback is load-bearing
      # for `render_prompt`'s empty-cfg default-arg path.
      def config_base_url(cfg)
        cfg.dig("screenote", "base_url") || Hive::Screenote::OAuthClient::DEFAULT_BASE_URL
      end

      def connected_base_url(credential, cfg)
        credential["base_url"].to_s.empty? ? config_base_url(cfg) : credential["base_url"]
      end

      def action_for(marker_name)
        case marker_name
        when :complete then "artifacts_collected"
        when :error then "error"
        else marker_name.to_s
        end
      end
    end
  end
end
