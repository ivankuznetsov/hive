module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProjectSandbox
      BOOTSTRAP_WORKFLOW = "proof-bootstrap".freeze

      attr_reader :workspace, :home, :hive_home

      def initialize(root:, candidate_argv:, git_path:, process_runner:, environment:,
                     document:)
        @root = File.expand_path(root)
        @candidate_argv = candidate_argv.map(&:to_s).freeze
        @git_path = File.expand_path(git_path)
        @process_runner = process_runner
        @environment = environment
        @document = document
        @workspace = File.join(@root, "workflow-creator-proof")
        @home = File.join(@root, "home")
        @hive_home = File.join(@root, "hive-home")
      end

      def prepare
        FileUtils.mkdir_p([ @workspace, @home, @hive_home ], mode: 0o700)
        run!([ @git_path, "init", "-b", "main" ], chdir: @workspace)
        run!([ @git_path, "config", "user.email", "proof@example.invalid" ], chdir: @workspace)
        run!([ @git_path, "config", "user.name", "Hive Proof" ], chdir: @workspace)
        secure_write(File.join(@workspace, "README.md"), "Hive workflow-creator proof\n")
        run!([ @git_path, "add", "README.md" ], chdir: @workspace)
        run!([ @git_path, "commit", "-m", "Seed proof project" ], chdir: @workspace)
        run!(
          [
            *@candidate_argv, "init", "--new-workflow", BOOTSTRAP_WORKFLOW,
            "--minimal", "--json", @workspace
          ],
          chdir: @workspace,
          environment: hive_environment
        )
        remove_bootstrap_workflow!
        verify!
        self
      rescue Failure
        raise
      rescue StandardError => e
        raise Failure.new(
          phase: "project_setup",
          reason: "project_setup_failed",
          detail: e.message
        )
      end

      private

      def hive_environment
        @environment.merge(
          "HOME" => @home,
          "HIVE_HOME" => @hive_home,
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
          "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
        )
      end

      def remove_bootstrap_workflow!
        state = File.join(@workspace, ".hive-state")
        FileUtils.rm_f(File.join(state, "workflows", "#{BOOTSTRAP_WORKFLOW}.yml"))
        FileUtils.rm_rf(File.join(state, "workflows", BOOTSTRAP_WORKFLOW))
        config_path = File.join(state, "config.yml")
        config = YAML.safe_load(File.read(config_path), aliases: false)
        config.delete("default_workflow")
        secure_write(config_path, YAML.dump(config))
        run!(
          [
            @git_path, "add", "-A", "--",
            "config.yml", "workflows/#{BOOTSTRAP_WORKFLOW}.yml",
            "workflows/#{BOOTSTRAP_WORKFLOW}"
          ],
          chdir: state
        )
        run!(
          [ @git_path, "commit", "-m", "Remove proof bootstrap workflow" ],
          chdir: state
        )
      end

      def verify!
        state = File.join(@workspace, ".hive-state")
        config = YAML.safe_load(File.read(File.join(state, "config.yml")), aliases: false)
        registration = YAML.safe_load(
          File.read(File.join(@hive_home, "config.yml")), aliases: false
        )
        projects = Array(registration["registered_projects"])
        valid_registration = projects.one? do |project|
          File.expand_path(project["path"].to_s) == @workspace &&
            File.expand_path(project["hive_state_path"].to_s) == state
        end
        return if File.directory?(state) && File.file?(File.join(state, ".git")) &&
                  config.is_a?(Hash) && valid_registration

        raise Failure.new(
          phase: "project_setup",
          reason: "project_identity_invalid",
          detail: "candidate did not create one registered hive/state worktree"
        )
      end

      def run!(argv, chdir:, environment: @environment)
        result = @process_runner.call(
          environment: environment,
          argv: argv,
          chdir: chdir
        )
        @document.record_process(
          result,
          label: "project_setup/#{File.basename(argv.fetch(0).to_s)}"
        )
        return result if result.fetch("status")&.success? &&
                         result.dig("record", "teardown", "status") == "passed" &&
                         result.fetch("secret_findings").empty?

        detail = result.fetch("stderr").to_s.scrub.lines.first(8).join
        raise Failure.new(
          phase: "project_setup",
          reason: "project_command_failed",
          detail: "#{File.basename(argv.fetch(0))} failed: #{detail}"
        )
      end

      def secure_write(path, content)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(content)
        end
      end
    end
  end
end
