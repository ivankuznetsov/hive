require "fileutils"
require "open3"
require "hive/stages/agent"
require "hive/stages/base"

module Hive
  module Stages
    module Council
      class Reviewer
        def self.run!(task:, cfg:, stage:, reviewer:, round:, target_path:)
          new(task: task, cfg: cfg, stage: stage, reviewer: reviewer, round: round, target_path: target_path).run!
        end

        def initialize(task:, cfg:, stage:, reviewer:, round:, target_path:)
          @task = task
          @cfg = cfg || {}
          @stage = stage
          @reviewer = reviewer
          @round = round
          @target_path = target_path
        end

        def run!
          FileUtils.mkdir_p(File.dirname(output_path))
          if @reviewer.command
            run_command!
          else
            run_agent!
          end
          output_path
        end

        private

        def run_command!
          env = {
            "HIVE_COUNCIL_INPUT" => @target_path,
            "HIVE_COUNCIL_OUTPUT" => output_path,
            "HIVE_COUNCIL_ROUND" => @round.to_s
          }
          _stdout, stderr, status = Open3.capture3(env, "sh", "-c", @reviewer.command, chdir: @task.folder)
          return if status.success? && File.exist?(output_path) && File.size(output_path).positive?

          raise Hive::StageError,
                "council reviewer #{@reviewer.name} failed: #{stderr.to_s.strip[0, 200]}"
        end

        def run_agent!
          profile = Hive::Stages::Base.stage_profile(@cfg, @stage.name, explicit_agent: @reviewer.agent || @stage.agent)
          scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
            @cfg,
            @stage.name,
            @task,
            profile,
            **permission_kwargs
          )
          result = Hive::Stages::Base.spawn_agent(
            @task,
            prompt: prompt(profile),
            add_dirs: scope.fetch(:add_dirs),
            cwd: @task.folder,
            max_budget_usd: @cfg.dig("budget_usd", @stage.name) || @stage.budget_usd,
            timeout_sec: @cfg.dig("timeout_sec", @stage.name) || @stage.timeout_sec || Hive::Stages::Agent::DEFAULT_TIMEOUT_SEC,
            log_label: "#{@stage.name}-#{@reviewer.name}",
            profile: profile,
            model: @reviewer.model || @stage.model,
            effort: @reviewer.effort || @stage.effort,
            expected_output: output_path,
            status_mode: :output_file_exists,
            cfg: @cfg,
            **Hive::Stages::Base.tool_scope_kwargs(scope)
          )
          return if result[:status] == :ok

          raise Hive::StageError,
                "council reviewer #{@reviewer.name} failed: #{result[:error_message].to_s[0, 200]}"
        end

        def prompt(profile)
          skill_invocation = @reviewer.skill && profile.format_skill_invocation(@reviewer.skill)
          instruction_body = @reviewer.instruction && File.read(@reviewer.instruction)
          Hive::Stages::Base.render(
            "council_reviewer_prompt.md.erb",
            Hive::Stages::Base::TemplateBindings.new(
              reviewer_name: @reviewer.name,
              target_path: @target_path,
              output_path: output_path,
              output_file: output_path,
              round: @round,
              document: File.read(@target_path),
              skill_invocation: skill_invocation,
              instruction_body: instruction_body,
              prompt_body: @reviewer.prompt,
              user_supplied_tag: Hive::Stages::Base.user_supplied_tag
            )
          )
        end

        def output_path
          @output_path ||= begin
            base = @reviewer.output_basename || @reviewer.name
            safe = base.gsub(/[^a-zA-Z0-9_.-]+/, "-")
            File.join(@task.folder, "reviews", "#{safe}-#{format('%02d', @round)}.md")
          end
        end

        def permission_kwargs
          @reviewer.permissions.nil? ? {} : { explicit_permission_spec: @reviewer.permissions }
        end
      end
    end
  end
end
