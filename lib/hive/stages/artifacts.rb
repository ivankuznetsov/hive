require "fileutils"
require "json"
require "hive/claude_launcher"
require "hive/markers"
require "hive/screenote_uploader"
require "hive/stages/base"

module Hive
  module Stages
    module Artifacts
      module_function

      # Aggregate wall-clock budget for the synchronous screenote upload loop.
      # Each request is bounded (open 10s / read 60s) but the loop runs inside
      # the daemon dispatch cycle, so several stills against a slow endpoint
      # could otherwise serialize to N x 60s of blocking. Stop starting new
      # uploads once this is exceeded; unfinished stills are retried on a later
      # run (their screenote_url stays blank).
      SCREENOTE_UPLOAD_BUDGET_SEC = 120

      def run!(task, cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: :complete } if marker.name == :complete

        profile = Hive::Stages::Base.stage_profile(cfg, "artifacts")
        prompt = render_prompt(task)
        spawn_artifacts_agent(task, cfg, prompt, profile)
        marker = Hive::Markers.current(task.state_file)
        push_manifest_media_to_screenote(task) if marker.name == :complete
        { commit: action_for(marker.name), status: marker.name }
      end

      def spawn_artifacts_agent(task, cfg, prompt, profile)
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
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("7-artifacts", task),
            allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
      end

      def render_prompt(task)
        Hive::Stages::Base.render(
          "artifacts_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: task.worktree_path,
            artifact_file: task.state_file,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def action_for(marker_name)
        case marker_name
        when :complete then "artifacts_collected"
        when :error then "error"
        else marker_name.to_s
        end
      end

      def push_manifest_media_to_screenote(task, uploader: nil, screenote_config: nil)
        manifest_path = media_manifest_path(task)
        return unless File.file?(manifest_path)

        manifest = JSON.parse(File.read(manifest_path))
        return unless manifest["status"] == "captured"

        uploader ||= screenote_uploader(screenote_config || Hive::Config.load_global_screenote)
        return unless uploader

        changed = false
        items = manifest["items"].is_a?(Array) ? manifest["items"] : []
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCREENOTE_UPLOAD_BUDGET_SEC
        items.each do |item|
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            warn "[hive] screenote upload budget (#{SCREENOTE_UPLOAD_BUDGET_SEC}s) exceeded; " \
                 "leaving remaining stills for a later run"
            break
          end
          next unless upload_item_to_screenote?(item)

          file_path = media_item_path(task, item["file"])
          next unless file_path && File.file?(file_path)

          result = uploader.upload(path: file_path, title: item["caption"].to_s.empty? ? item["file"].to_s : item["caption"].to_s)
          url = result ? result["annotate_url"].to_s : ""
          next if url.empty?

          item["screenote_url"] = url
          changed = true
        end

        File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n") if changed
      rescue JSON::ParserError => e
        warn "[hive] media manifest is not valid JSON: #{e.message}"
      rescue Hive::ConfigError => e
        # A misconfigured screenote endpoint (e.g. a fat-fingered
        # HIVE_SCREENOTE_BASE_URL) must not raise into the pipeline, but it is
        # an operator error distinct from a transient upload blip — warn loudly
        # and specifically so it isn't flattened into the generic message.
        warn "[hive] screenote is misconfigured; skipping uploads: #{e.message}"
      rescue StandardError => e
        warn "[hive] screenote manifest processing failed: #{e.class}: #{e.message}"
      end

      def screenote_uploader(screenote_config)
        base_url = screenote_config["base_url"].to_s.strip
        api_token = screenote_config["api_token"].to_s.strip
        return nil if base_url.empty? || api_token.empty?

        Hive::ScreenoteUploader.new(base_url: base_url, api_token: api_token)
      end

      def media_manifest_path(task)
        File.join(task.folder, "media", "manifest.json")
      end

      def upload_item_to_screenote?(item)
        return false unless item.is_a?(Hash)
        return false unless item["push_to_screenote"] == true
        return false unless item["screenote_url"].to_s.strip.empty?

        %w[.png .jpg .jpeg].include?(File.extname(item["file"].to_s).downcase)
      end

      def media_item_path(task, filename)
        name = filename.to_s
        return nil if name.empty? || File.basename(name) != name

        media_dir = File.expand_path(File.join(task.folder, "media"))
        return nil unless File.directory?(media_dir)

        # Resolve symlinks on both sides and require the real target to stay
        # under the real media dir, so an agent-produced `media/01-home.png`
        # symlink can't exfiltrate an arbitrary readable host file to
        # screenote. Mirrors the web controller's resolved_media_path.
        media_root = File.realpath(media_dir)
        candidate = File.join(media_root, name)
        return nil unless File.file?(candidate)

        real = File.realpath(candidate)
        return nil unless real.start_with?("#{media_root}#{File::SEPARATOR}")

        real
      rescue SystemCallError
        nil
      end
    end
  end
end
