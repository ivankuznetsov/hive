require "fileutils"
require "hive/stages/base"
require "hive/stages/council/command_runner"

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
          # Honor the parsed `max_attempts` (defaults to 1): retry a failed
          # reviewer spawn/command up to that many times before surfacing the
          # failure to the council. Without this loop the field parsed and
          # validated in the descriptor would be a silent no-op.
          attempts = @reviewer.max_attempts || 1
          last_error = nil
          attempts.times do
            # Clear any stale output from a prior attempt/resume before running.
            # Both success paths (command exit + :output_file_exists) treat a
            # non-empty output file as a pass, so a leftover <name>-NN.md from an
            # earlier failed attempt or an interrupted run would falsely satisfy
            # the check and count toward quorum without this reviewer producing
            # a fresh verdict.
            FileUtils.rm_f(output_path)
            begin
              if @reviewer.command
                run_command!
              else
                run_agent!
              end
              return output_path
            rescue Hive::StageError => e
              last_error = e
            end
          end
          raise last_error
        end

        private

        def run_command!
          env = {
            "HIVE_COUNCIL_INPUT" => @target_path,
            "HIVE_COUNCIL_OUTPUT" => output_path,
            "HIVE_COUNCIL_ROUND" => @round.to_s
          }
          stderr, status = Hive::Stages::Council::CommandRunner.run(
            env,
            @reviewer.command,
            chdir: @task.folder,
            timeout_sec: timeout_sec,
            label: "council reviewer #{@reviewer.name}"
          )
          return if status.success? && File.size?(output_path)

          raise Hive::StageError,
                "council reviewer #{@reviewer.name} failed: #{stderr.to_s.strip[0, 200]}"
        end

        def run_agent!
          identity = launch_identity
          profile = Hive::Stages::Base.stage_profile(@cfg, @stage.name, explicit_agent: identity.fetch(:agent))
          resource_limits = Hive::Stages::Base.stage_resource_limits(@cfg, @stage)
          actor_prompt, scope = Hive::Stages::Base.actor_prompt_and_scope(
            @cfg,
            @stage.name,
            @task,
            profile,
            prompt: prompt(profile),
            managed_slot: "stages.#{@stage.name}.reviewers.#{@reviewer.name}",
            managed_outputs: [ @output_path ],
            **permission_kwargs
          )
          result = Hive::Stages::Base.spawn_agent(
            @task,
            prompt: actor_prompt,
            add_dirs: scope.fetch(:add_dirs),
            cwd: @task.folder,
            **resource_limits,
            log_label: "#{@stage.name}-#{@reviewer.name}",
            profile: profile,
            model: identity[:model],
            effort: identity[:effort],
            expected_output: output_path,
            status_mode: :output_file_exists,
            cfg: @cfg,
            **Hive::Stages::Base.tool_scope_kwargs(scope)
          )
          return if result[:status] == :ok

          raise Hive::StageError,
                "council reviewer #{@reviewer.name} failed: #{result[:error_message].to_s[0, 200]}"
        end

        def launch_identity
          unless @task.respond_to?(:managed_workflow?) && @task.managed_workflow?
            return {
              agent: @reviewer.agent || @stage.agent,
              model: @reviewer.model || @stage.model,
              effort: @reviewer.effort || @stage.effort
            }
          end

          if @reviewer.agent.to_s.empty?
            raise Hive::ConfigError,
                  "managed council reviewer #{@reviewer.name} is missing its mapped agent"
          end
          { agent: @reviewer.agent, model: @reviewer.model, effort: @reviewer.effort }
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

        def timeout_sec
          Hive::Stages::Base.stage_resource_limits(@cfg, @stage).fetch(:timeout_sec)
        end

        # Reviewer verdict files always live in `reviews/<base>-NN.md`, a fixed
        # directory that does NOT track `council.triage_output`'s dir (triage
        # derives its own dir via File.dirname(triage_output)). This split is
        # intentional and not a functional bug: review paths are handed to
        # Triage explicitly (never globbed), so a custom `triage_output: audit/…`
        # relocates only the triage artifact while reviewer files stay in
        # reviews/.
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
