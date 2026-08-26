# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "../paths"
require_relative "state_snapshotter"

module HiveReleaseCandidate
  class UpgradeSurvivor
    class FixedPhaseExecutor
      COMMANDS = {
        "latest-stable" => {
          "before" => [ [ "init", "%PROJECT%" ], [ "new", "%PROJECT_NAME%", "release candidate representative task", "--json" ] ],
          "candidate_transition" => [ [ "migrate", "%PROJECT%", "--json" ] ],
          "after" => [ [ "status", "--operational", "--json" ] ],
          "idempotency" => [ [ "migrate", "%PROJECT%", "--json" ] ]
        },
        "legacy-bench-v041" => {
          "before" => [
            [ "init", "%PROJECT%" ],
            [ "new", "%PROJECT_NAME%", "legacy bench campaign", "--workflow", "bench", "--json" ]
          ],
          "observer" => [
            [ "new", "%PROJECT_NAME%", "collision observer", "--workflow", "bench", "--json" ]
          ],
          "candidate_transition" => [ [ "init", "%PROJECT%", "--workflow", "bench", "--json" ] ],
          "after" => [ [ "status", "--operational", "--json" ] ],
          "idempotency" => [ [ "init", "%PROJECT%", "--workflow", "bench", "--json" ] ]
        }
      }.freeze
      LEGACY_INSTRUCTIONS = %w[extract generate judge publish].to_h do |stage|
        [ "#{stage}.md", "Legacy local #{stage} instructions.\n" ]
      end.freeze
      LEGACY_DESCRIPTOR = <<~YAML.freeze
        id: bench
        stages:
          - name: inbox
            kind: terminal
            state_file: task.md
          - name: extract
            kind: agent
            state_file: extract.md
            instruction: ./bench/extract.md
            advance_verb: extract
          - name: generate
            kind: agent
            state_file: generate.md
            instruction: ./bench/generate.md
            advance_verb: generate
          - name: judge
            kind: agent
            state_file: judge.md
            instruction: ./bench/judge.md
            advance_verb: judge
          - name: publish
            kind: agent
            state_file: publish.md
            instruction: ./bench/publish.md
            advance_verb: publish
          - name: done
            kind: terminal
            state_file: task.md
      YAML

      def initialize(process_teardown:)
        @process_teardown = process_teardown
        @state_snapshotter = StateSnapshotter.new(process_teardown: process_teardown)
      end

      def call(target:, phase:, row:, run_root:)
        project = File.join(run_root, "project")
        environment = target.environment.merge(
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
          "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
        )
        %w[HOME HIVE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME].each do |key|
          FileUtils.mkdir_p(environment.fetch(key))
        end
        prepare_source_project!(project) if phase == "before"
        receipts = []
        COMMANDS.fetch(row.id).fetch(phase).each_with_index do |template, index|
          argv = template.map do |argument|
            argument.gsub("%PROJECT%", project).gsub("%PROJECT_NAME%", File.basename(project))
          end
          receipt = @process_teardown.capture(
            target: target, argv: argv, environment: environment,
            cwd: run_root, label: "#{row.id}:#{phase}:#{index + 1}"
          )
          receipts << receipt
          if row.id == "legacy-bench-v041" && phase == "before" && index.zero? && receipt["status"] == "passed"
            install_exact_legacy_bench!(project)
          end
          break unless receipt["status"] == "passed" || phase == "observer"
        end
        seed_representative_state!(
          project: project, environment: environment
        ) if phase == "before" && receipts.all? { |item| item["status"] == "passed" }
        receipt = combine(receipts)
        if phase == "observer"
          exact_collision = receipt["status"] == "failed" &&
            receipt["stderr"].include?("collides with registered workflow :bench")
          receipt = receipt.merge(
            "status" => exact_collision ? "expected_failure_observed" : receipt["status"],
            "reason" => exact_collision ? "legacy_workflow_collision" : "observer_outcome_mismatch",
            "observation" => exact_collision ? {
              "outcome" => "expected_failure",
              "code" => "workflow_id_collision:bench"
            } : nil
          )
        end
        receipt.merge(
          "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => @state_snapshotter.call(
            target: target, row: row, project: project, environment: environment
          ),
          "task_continuation" => phase == "after" ? @state_snapshotter.task_present?(project) : nil,
          "processes" => [], "services" => []
        )
      end

      private

      def prepare_source_project!(project)
        FileUtils.mkdir_p(project)
        return if File.directory?(File.join(project, ".git"))

        run_git!(project, "init", "-b", "main")
        run_git!(project, "config", "user.email", "release-candidate@example.invalid")
        run_git!(project, "config", "user.name", "Hive Release Candidate")
        File.write(File.join(project, "README.md"), "release candidate upgrade fixture\n")
        run_git!(project, "add", "README.md")
        run_git!(project, "commit", "-m", "fixture root")
      end

      def run_git!(project, *argv)
        _stdout, stderr, status = Open3.capture3(
          { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0" },
          "git", *argv, chdir: project
        )
        raise Error, "cannot prepare upgrade source project: #{stderr.strip}" unless status.success?
      end

      def install_exact_legacy_bench!(project)
        root = File.join(project, ".hive-state", "workflows")
        instruction_root = File.join(root, "bench")
        FileUtils.mkdir_p(instruction_root)
        File.write(File.join(root, "bench.yml"), LEGACY_DESCRIPTOR)
        LEGACY_INSTRUCTIONS.each do |name, content|
          File.write(File.join(instruction_root, name), content)
        end
        run_git!(File.join(project, ".hive-state"), "add", "workflows")
        run_git!(
          File.join(project, ".hive-state"), "commit", "-m",
          "install exact legacy bench descriptor"
        )
      end

      def combine(receipts)
        {
          "status" => receipts.all? { |item| item["status"] == "passed" } ? "passed" : "failed",
          "exit_status" => receipts.last && receipts.last["exit_status"],
          "stdout" => receipts.map { |item| item["stdout"] }.join,
          "stderr" => receipts.map { |item| item["stderr"] }.join,
          "commands" => receipts.map do |item|
            item.slice("label", "role", "argv", "status", "exit_status")
          end
        }
      end

      def seed_representative_state!(project:, environment:)
        state = File.join(project, ".hive-state")
        task = Dir.glob(File.join(state, "stages", "*", "*")).sort.find do |path|
          File.directory?(path) && !File.symlink?(path)
        end
        if task
          state_file = Dir.glob(File.join(task, "*.md")).sort.first
          File.open(state_file, "a") { |file| file.write("\n<!-- WAITING -->\n") } if state_file
        end
        attempt_root = File.join(state, "attempts", "upgrade-fixture-attempt")
        receipt_root = File.join(state, "dispatch-receipts")
        FileUtils.mkdir_p([ attempt_root, receipt_root ])
        File.write(File.join(attempt_root, "record.json"), JSON.generate(
          "schema" => "hive-attempt", "outcome" => "terminal",
          "task_id" => 7
        ))
        File.write(File.join(receipt_root, "upgrade-fixture-attempt.json"), JSON.generate(
          "schema" => "hive-dispatch-receipt", "accepted" => true,
          "task_id" => 7
        ))
        File.write(File.join(environment.fetch("HIVE_HOME"), "install-channel"), "bash\n")
        web = File.join(environment.fetch("XDG_DATA_HOME"), "hive", "web")
        services = File.join(environment.fetch("XDG_CONFIG_HOME"), "systemd", "user")
        FileUtils.mkdir_p([ web, services ])
        File.write(File.join(web, "persistent-data.fixture"), "preserve-across-upgrade\n")
        %w[hive-daemon hive-web].each do |name|
          File.write(
            File.join(services, "#{name}.service"),
            "[Unit]\nDescription=Inert #{name} upgrade fixture\n"
          )
        end
      end
    end
  end
end
