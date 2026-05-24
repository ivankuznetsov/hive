require "json"
require "tmpdir"
require "yaml"
require "hive/bot/status_watcher"

module Hive
  module Eval
    module ScenarioSupport
      include Hive::Eval::ContractAssertions if defined?(Hive::Eval::ContractAssertions)

      DEFAULT_PROJECT = "hive"

      def before_setup
        super
        @hive_eval_old_env = {
          "HIVE_HOME" => ENV["HIVE_HOME"],
          "HOME" => ENV["HOME"]
        }
        @scenario_home = Dir.mktmpdir("hive-eval")
        ENV["HIVE_HOME"] = @scenario_home
        ENV["HOME"] = @scenario_home
        @hive_eval_projects = []
        @hive_eval_assertions = []
        write_global_config
      end

      def after_teardown
        FileUtils.rm_rf(@scenario_home) if @scenario_home
        @hive_eval_old_env&.each do |key, value|
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
        super
      end

      def scenario_home
        @scenario_home
      end

      def harness
        @harness ||= Hive::Eval::Harness.new
      end

      def given_project(name: DEFAULT_PROJECT, path: nil, daemon_enabled: false)
        project_path = path || File.join(scenario_home, name)
        hive_state_path = File.join(project_path, ".hive-state")
        FileUtils.mkdir_p(File.join(hive_state_path, "stages"))
        File.write(File.join(hive_state_path, "config.yml"), {
          "daemon" => { "enabled" => daemon_enabled }
        }.to_yaml)
        @hive_eval_projects << {
          "name" => name,
          "path" => project_path,
          "hive_state_path" => hive_state_path
        }
        write_global_config
        project_path
      end

      def given_brainstorm(project: DEFAULT_PROJECT, slug:, content: nil)
        project_entry = @hive_eval_projects.find { |entry| entry["name"] == project } ||
          raise("project #{project.inspect} has not been registered")
        path = File.join(project_entry.fetch("hive_state_path"), "stages", "2-brainstorm", slug, "brainstorm.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content || default_brainstorm_content)
        path
      end

      def status_row(project: DEFAULT_PROJECT, slug: "task-a", stage: "2-brainstorm",
                     marker: "waiting", attrs: {}, action: "needs_input",
                     action_label: nil, diagnostic: nil)
        Hive::Bot::StatusWatcher::Row.new(
          project: project,
          project_path: project_path(project),
          hive_state_path: hive_state_path(project),
          slug: slug,
          stage: stage,
          marker: marker,
          attrs: attrs,
          action: action,
          action_label: action_label || action.tr("_", " "),
          diagnostic: diagnostic
        )
      end

      def when_user_sends(text, **opts)
        harness.when_user_sends(text, **opts)
      end

      def when_user_taps(callback_data, **opts)
        harness.when_user_taps(callback_data, **opts)
      end

      def when_agent_emits(rows:)
        harness.status_tick!(rows: rows)
      end

      def when_clock_advances(seconds)
        harness.advance(seconds)
      end

      def assert_sent_count(count)
        assert_equal count, harness.sent.length,
                     "expected #{count} sent Telegram payloads, got #{harness.sent.length}: " \
                     "#{harness.sent.map(&:text).inspect}"
      end

      def eval_assertions
        @hive_eval_assertions
      end

      private

      def write_global_config
        FileUtils.mkdir_p(scenario_home)
        File.write(File.join(scenario_home, "config.yml"), {
          "registered_projects" => @hive_eval_projects,
          "bot" => { "chat_id_allowlist" => [ Hive::Eval::FakeTelegram::DEFAULT_CHAT_ID ] }
        }.to_yaml)
      end

      def project_path(project)
        @hive_eval_projects.find { |entry| entry["name"] == project }&.fetch("path", nil)
      end

      def hive_state_path(project)
        @hive_eval_projects.find { |entry| entry["name"] == project }&.fetch("hive_state_path", nil)
      end

      def default_brainstorm_content
        <<~MARKDOWN
          ## Round 1

          ### Q1. What should Hive do next?

          ### A1.

          <!-- WAITING -->
        MARKDOWN
      end
    end
  end
end
