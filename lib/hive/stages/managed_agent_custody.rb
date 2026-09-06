require "json"
require "hive/atomic_file"
require "hive/artifact_firewall"
require "hive/attempts/context"
require "hive/patrol_fix/attempt_diagnostic"
require "hive/patrol_fix/agent_git_isolation"
require "hive/stages/base"

module Hive
  module Stages
    # Local controller-custody primitives shared by managed agent stages.
    # This module does not create worktrees, authenticate, publish, or decide
    # stage outcomes; those remain responsibilities of the owning workflow.
    module ManagedAgentCustody
      module_function

      def manifest(root:, worktree_path:, protected_task_paths:, required_outputs:,
                   git_control_paths: nil)
        controls = git_control_paths || self.git_control_paths!(worktree_path)
        Hive::ArtifactFirewall::Manifest.new(
          root: root,
          protected_anchors: protected_task_paths.merge(controls),
          permitted_writable_roots: [ root, worktree_path ],
          required_outputs: required_outputs
        )
      end

      def git_control_paths!(worktree_path)
        Hive::PatrolFix::AgentGitIsolation.git_control_paths!(worktree_path)
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
        admitted_launch_context = Hive::Stages::Base.admitted_launch_context(
          cfg: cfg, profile: profile
        )
        profile = admitted_launch_context.fetch(:profile)
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
        git_controls = git_control_paths!(cwd)
        custody = Hive::ArtifactFirewall::AgentCustody.new(
          manifest(
            root: task.folder, worktree_path: cwd,
            protected_task_paths: protected_task_paths,
            required_outputs: { output_label => output_path },
            git_control_paths: git_controls
          ),
          before_validation: lambda { |result|
            materialize_exact_final_json(result, output_path)
          }
        )
        isolation = Hive::PatrolFix::AgentGitIsolation.prepare!(
          worktree_path: cwd, task_folder: task.folder,
          writable_worktree: fixing, profile: profile,
          git_control_paths: git_controls,
          provider_environment: admitted_launch_context.fetch(:launch_binding)&.environment || {}
        )
        begin
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
            status_mode: :exit_code_only, cfg: cfg, agent_custody: custody,
            command_prefix: isolation.command_prefix,
            launch_environment: isolation.environment,
            admitted_launch_context: admitted_launch_context
          )
          report = custody.report
          provisional_status = result.is_a?(Hash) ? result[:status] : :error
          provisional_status = :ok if recovered_provider_retry?(result, report)
          if fixing && provisional_status == :ok && report&.valid?
            isolation.adopt_if_changed!
          end
        ensure
          isolation.cleanup!
        end
        custody_status = if report&.tampered?
          :tampered
        elsif report&.required_outputs_valid? == false
          :invalid_output
        else
          :clean
        end
        status = result.is_a?(Hash) ? result[:status] : :error
        status = :ok if recovered_provider_retry?(result, report)
        response = {
          status: status,
          custody: custody_status,
          diagnostic: report&.diagnostic
        }
        envelope = diagnostic_envelope(
          result, report, status: status, custody_status: custody_status,
          provider: profile.name
        )
        if status != :ok || custody_status != :clean
          diagnostic = publish_attempt_diagnostic(envelope, stage: stage)
          response[:attempt_diagnostic] = diagnostic if diagnostic
        end
        response
      end

      def publish_report_invalid(stage:, parser:, detail:)
        publish_attempt_diagnostic(
          {
            "phase" => "report_admission", "status" => "error", "exit_code" => 0,
            "timed_out" => false, "cancelled" => false, "signal" => nil,
            "report_status" => "invalid", "report_parser" => parser,
            "firewall_status" => "clean", "custody_status" => "clean",
            "detail" => detail
          },
          stage: stage
        )
      end

      def publish_controller_failure(stage:, error:)
        publish_attempt_diagnostic(
          controller_failure_envelope(stage: stage, error: error),
          stage: stage
        )
      end

      def read_report(stage:, parser:, invalid_report:)
        yield
      rescue invalid_report => e
        publish_report_invalid(stage: stage, parser: parser, detail: e.message)
        raise
      end

      def publish_attempt_diagnostic(envelope, stage:)
        context = Hive::Attempts::Context.current
        return nil unless context

        diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
          envelope,
          stage: context.intended_stage || stage,
          task_generation: context.ownership_generation,
          attempt_id: context.attempt_id,
          recorded_at: Time.now.utc
        )
        context.publish_attempt_diagnostic(diagnostic)
        diagnostic
      rescue Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic, IOError, SystemCallError
        nil
      end

      def controller_failure_envelope(stage:, error:)
        message = error.message.to_s
        envelope = {
          "phase" => "controller",
          "status" => "error",
          "exit_code" => nil,
          "timed_out" => false,
          "cancelled" => false,
          "signal" => nil,
          "report_status" => "not_applicable",
          "firewall_status" => "not_applicable",
          "custody_status" => "unknown",
          "detail" => message
        }
        if error.respond_to?(:code) && error.code.to_s == "secret_detected"
          envelope.merge!(
            "phase" => "publication",
            "publication_status" => "blocked_by_policy"
          )
        elsif message.include?("index.lock")
          envelope.merge!(
            "phase" => "state_git_write",
            "write_status" => "lock_conflict"
          )
        elsif stage.to_s == "validate" && message.include?("validation changed")
          envelope.merge!(
            "phase" => "validation_custody",
            "authoritative_state_changed" => true,
            "custody_status" => "mutation"
          )
        elsif message.match?(/worktree (?:is dirty|bytes changed)/i)
          envelope.merge!(
            "phase" => "fix_worktree_preflight",
            "worktree_status" => "dirty",
            "custody_status" => "dirty"
          )
        elsif message.match?(/worktree HEAD changed|HEAD custody/i)
          envelope.merge!(
            "phase" => "worktree_custody",
            "head_relation" => "unexpected_movement",
            "custody_status" => "head_drift"
          )
        end
        envelope
      end
      private_class_method :controller_failure_envelope

      def diagnostic_envelope(result, report, status:, custody_status:, provider:)
        source = result.is_a?(Hash) ? result : {}
        restore_status = { true => "restored", false => "failed" }.fetch(
          report&.restored?, "not_attempted"
        )
        provider_failure = source[:provider_error].is_a?(Hash) ||
          source[:provider_signal].is_a?(Hash)
        {
          "phase" => "managed_agent",
          "status" => status.to_s,
          "exit_code" => source[:exit_code],
          "timed_out" => source[:timed_out] == true,
          "cancelled" => source[:cancelled] == true,
          "signal" => source[:signal],
          "error_reason" => source[:error_reason],
          "provider" => provider.to_s,
          "provider_error" => source[:provider_error],
          "provider_signal" => source[:provider_signal],
          "retry_at" => source[:retry_at],
          "provider_provenance" => source[:final_message_source],
          "report_status" => report&.required_outputs_valid? ? "valid" : "invalid",
          "report_parser" => source[:final_message_source],
          "firewall_status" => report&.status&.to_s || "unavailable",
          "restore_status" => restore_status,
          "custody_status" => custody_status.to_s,
          "protected_git_config_changed" => protected_git_config_changed?(report),
          "detail" => provider_failure ? nil : (source[:error_message] || report&.diagnostic)
        }
      end
      private_class_method :diagnostic_envelope

      def protected_git_config_changed?(report)
        Array(report&.tampered_labels).any? do |label|
          label.to_s.match?(/(?:git config|repository config|worktree config)/i)
        end
      end
      private_class_method :protected_git_config_changed?

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
    end
  end
end
