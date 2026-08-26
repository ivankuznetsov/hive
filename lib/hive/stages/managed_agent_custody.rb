require "open3"
require "json"
require "hive/atomic_file"
require "hive/artifact_firewall"
require "hive/stages/base"

module Hive
  module Stages
    # Local controller-custody primitives shared by managed agent stages.
    # This module does not create worktrees, authenticate, publish, or decide
    # stage outcomes; those remain responsibilities of the owning workflow.
    module ManagedAgentCustody
      module_function

      def manifest(root:, worktree_path:, protected_task_paths:, required_outputs:)
        Hive::ArtifactFirewall::Manifest.new(
          root: root,
          protected_anchors: protected_task_paths.merge(git_control_paths!(worktree_path)),
          permitted_writable_roots: [ root, worktree_path ],
          required_outputs: required_outputs
        )
      end

      def launch_agent(task:, cfg:, prompt:, output_path:, protected_files:,
                       actor:, slot:, cwd:, add_dirs:, stage:, log_label:)
        validate_regular_or_absent!(task.folder, protected_files)
        output_label = File.basename(output_path)
        prepare_output!(output_path, label: output_label)
        fix = cfg.dig("patrol", "fix")
        fix = {} unless fix.is_a?(Hash)
        fix_agent = fix["agent"]
        fixing = actor == "patrol_fix"
        profile = Hive::Stages::Base.stage_profile(
          cfg, "patrol", explicit_agent: fixing ? fix_agent : nil
        )
        model_actor = fixing ? "patrol_fix" : actor
        model_current = if fixing
          fix_model_routing_current(cfg, fix, fix_agent)
        else
          Hive::Stages::Base.model_routing_current(cfg["patrol"])
        end
        prompt = <<~PROMPT
          #{prompt.rstrip}

          After writing the required report, stop using tools.
          Return that same JSON object as your complete final response.
          Do not wrap it in Markdown or add prose.
        PROMPT
        support = Hive::AgentProfiles.support_for(profile)
        prompt, scope = if support&.const_defined?(:LaunchPolicy, false)
          support::LaunchPolicy.custody_scope(
            prompt:, task_root: task.folder, actor:, cwd:, add_dirs:, output_path:
          )
        else
          Hive::Stages::Base.actor_prompt_and_scope(
            cfg, actor, task, profile,
            prompt: prompt, base_add_dirs: add_dirs,
            managed_slot: slot, managed_outputs: [ output_path ],
            mark_permission_error: false
          )
        end
        protected_task_paths = protected_files.to_h do |name|
          [ name, File.join(task.folder, name) ]
        end
        custody = Hive::ArtifactFirewall::AgentCustody.new(
          manifest(
            root: task.folder, worktree_path: cwd,
            protected_task_paths: protected_task_paths,
            required_outputs: { output_label => output_path }
          ),
          before_validation: lambda { |result|
            materialize_exact_final_json(result, output_path)
          }
        )
        result = Hive::Stages::Base.spawn_agent(
          task, prompt: prompt, add_dirs: scope.fetch(:add_dirs), cwd: cwd,
          **Hive::Stages::Base.stage_resource_limits(
            cfg, task.workflow.stage_named(stage)
          ),
          log_label: log_label, profile: profile,
          **Hive::Stages::Base.model_launch_arguments(
            cfg, model_actor, profile, current: model_current
          ),
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          status_mode: :exit_code_only, cfg: cfg, agent_custody: custody
        )
        report = custody.report
        custody_status = if report&.tampered?
          :tampered
        elsif report&.required_outputs_valid? == false
          :invalid_output
        else
          :clean
        end
        status = result.is_a?(Hash) ? result[:status] : :error
        status = :ok if recovered_provider_retry?(result, report)
        {
          status: status,
          custody: custody_status,
          diagnostic: report&.diagnostic
        }
      end

      # Pi can emit a failed message_end, retry that provider turn internally,
      # then exit zero after writing the current report. Agent keeps the first
      # provider failure fail-closed because :exit_code_only has no artifact
      # evidence. This outer boundary does: a clean custody report proves the
      # required output exists and no controller anchor changed, so the later
      # successful result wins just as it does in :output_file_exists mode.
      def recovered_provider_retry?(result, report)
        result.is_a?(Hash) && provider_retry_candidate?(result) && report&.valid?
      end
      private_class_method :recovered_provider_retry?

      def materialize_exact_final_json(result, output_path)
        return unless result.is_a?(Hash) &&
          (result[:status] == :ok || provider_retry_candidate?(result))
        return if result[:final_message_truncated] == true
        return if File.exist?(output_path) || File.symlink?(output_path)

        value = JSON.parse(result[:final_message].to_s)
        return unless value.is_a?(Hash)

        Hive::AtomicFile.write(output_path, JSON.generate(value) + "\n", mode: 0o600)
      rescue JSON::ParserError
        nil
      end
      private_class_method :materialize_exact_final_json

      def provider_retry_candidate?(result)
        provider_error = result[:provider_error]
        return false unless result[:status] == :error && provider_error.is_a?(Hash)

        reason = result[:error_reason].to_s
        retry_failure = reason == "provider_error" ||
          (reason == "limits_reached" &&
            %i[provider_limit rate_limited].include?(provider_error[:kind].to_s.to_sym))
        retry_failure && result[:exit_code] == 0 && result[:timed_out] != true
      end
      private_class_method :provider_retry_candidate?

      def fix_model_routing_current(cfg, fix, fix_agent)
        patrol = Hive::Stages::Base.model_routing_current(cfg["patrol"])
        patrol_agent = cfg.dig("patrol", "agent") || "claude"
        if fix_agent && fix_agent.to_s != patrol_agent.to_s
          patrol = Hive::ModelRouting::EMPTY_MODELS
        end
        patrol.merge(Hive::Stages::Base.model_routing_current(fix))
      end
      private_class_method :fix_model_routing_current

      def validate_regular_or_absent!(root, names)
        names.each do |name|
          stat = File.lstat(File.join(root, name))
          unless stat.file? && !stat.symlink?
            raise Hive::StageError, "protected task file #{name} must be a regular file"
          end
        rescue Errno::ENOENT
          next
        end
      end

      def prepare_output!(path, label: File.basename(path))
        stat = File.lstat(path)
        raise Hive::StageError, "#{label} must be a regular file, not a symlink" if stat.symlink?
        raise Hive::StageError, "#{label} must be a regular file" unless stat.file?

        File.unlink(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, IOError => e
        raise Hive::StageError, "could not prepare #{label}: #{e.class}: #{e.message}"
      end

      def git_control_paths!(worktree_path)
        common = git_path!(worktree_path, "--path-format=absolute", "--git-common-dir")
        git_dir = git_path!(worktree_path, "--absolute-git-dir")
        paths = {
          "worktree .git pointer" => File.join(worktree_path, ".git"),
          "repository config" => File.join(common, "config"),
          "worktree config" => File.join(git_dir, "config.worktree")
        }
        home = ENV["HOME"].to_s
        unless home.empty?
          paths["global Git config"] = File.join(home, ".gitconfig")
          paths["XDG Git config"] = File.join(home, ".config", "git", "config")
        end
        xdg = ENV["XDG_CONFIG_HOME"].to_s
        paths["explicit XDG Git config"] = File.join(xdg, "git", "config") unless xdg.empty?
        global = ENV["GIT_CONFIG_GLOBAL"].to_s
        paths["global Git config override"] = global unless global.empty?
        system = ENV["GIT_CONFIG_SYSTEM"].to_s
        paths["system Git config override"] = system unless system.empty?
        unique_paths(paths, worktree_path)
      end

      def unique_paths(paths, root)
        seen = {}
        paths.each_with_object({}) do |(label, path), unique|
          expanded = File.expand_path(path, root)
          next if seen[expanded]

          seen[expanded] = true
          unique[label] = expanded
        end
      end
      private_class_method :unique_paths

      def git_path!(worktree_path, *args)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", *args)
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::StageError, "managed worktree Git control path is unavailable: #{detail[0, 200]}"
        end

        File.expand_path(out.to_s.strip, worktree_path)
      end
      private_class_method :git_path!
    end
  end
end
