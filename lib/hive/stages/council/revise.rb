require "hive/stages/base"
require "hive/stages/council/command_runner"

module Hive
  module Stages
    module Council
      class Revise
        def self.run!(task:, cfg:, stage:, revise:, round:, target_path:, triage_path:)
          new(task: task, cfg: cfg, stage: stage, revise: revise, round: round,
              target_path: target_path, triage_path: triage_path).run!
        end

        def initialize(task:, cfg:, stage:, revise:, round:, target_path:, triage_path:)
          @task = task
          @cfg = cfg || {}
          @stage = stage
          @revise = revise
          @round = round
          @target_path = target_path
          @triage_path = triage_path
        end

        def run!
          if @revise.command
            run_command!
          else
            run_agent!
          end
          true
        end

        private

        def run_command!
          env = {
            "HIVE_COUNCIL_INPUT" => @target_path,
            "HIVE_COUNCIL_TRIAGE" => @triage_path,
            "HIVE_COUNCIL_ROUND" => @round.to_s
          }
          stderr, status = Hive::Stages::Council::CommandRunner.run(
            env,
            @revise.command,
            chdir: @task.folder,
            timeout_sec: timeout_sec,
            label: "council revise"
          )
          return if status.success? && File.size?(@target_path)

          raise Hive::StageError, "council revise failed: #{stderr.to_s.strip[0, 200]}"
        end

        def run_agent!
          profile = Hive::Stages::Base.stage_profile(@cfg, @stage.name, explicit_agent: @revise.agent || @stage.agent)
          scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
            @cfg,
            @stage.name,
            @task,
            profile,
            **permission_kwargs
          )
          resource_limits = Hive::Stages::Base.stage_resource_limits(@cfg, @stage)
          result = Hive::Stages::Base.spawn_agent(
            @task,
            prompt: prompt(profile),
            add_dirs: scope.fetch(:add_dirs),
            cwd: @task.folder,
            **resource_limits,
            log_label: "#{@stage.name}-revise",
            profile: profile,
            model: @revise.model || @stage.model,
            effort: @revise.effort || @stage.effort,
            expected_output: @target_path,
            status_mode: :output_file_exists,
            cfg: @cfg,
            **Hive::Stages::Base.tool_scope_kwargs(scope)
          )
          return if result[:status] == :ok

          raise Hive::StageError, "council revise failed: #{result[:error_message].to_s[0, 200]}"
        end

        def prompt(profile)
          skill_invocation = @revise.skill && profile.format_skill_invocation(@revise.skill)
          instruction_body = @revise.instruction && File.read(@revise.instruction)
          Hive::Stages::Base.render(
            "council_revise_prompt.md.erb",
            Hive::Stages::Base::TemplateBindings.new(
              target_path: @target_path,
              triage_path: @triage_path,
              round: @round,
              document: File.read(@target_path),
              triage: File.read(@triage_path),
              skill_invocation: skill_invocation,
              instruction_body: instruction_body,
              prompt_body: @revise.prompt,
              user_supplied_tag: Hive::Stages::Base.user_supplied_tag
            )
          )
        end

        def timeout_sec
          Hive::Stages::Base.stage_resource_limits(@cfg, @stage).fetch(:timeout_sec)
        end

        def permission_kwargs
          @revise.permissions.nil? ? {} : { explicit_permission_spec: @revise.permissions }
        end
      end
    end
  end
end
