require "date"
require "fileutils"
require "json"
require "logger"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/config"
require "hive/digest/errors"
require "hive/digest/shipped_item"
require "hive/digest/window"
require "hive/paths"
require "hive/stages/base"

module Hive
  module Digest
    CategorizedItem = Data.define(:item, :category, :summary)

    class Categorizer
      VALID_CATEGORIES = %w[feature fix patrol].freeze
      DEFAULT_CATEGORY = "feature".freeze
      DEFAULT_BUDGET_USD = 50
      DEFAULT_TIMEOUT_SEC = 1800

      RunnerTask = Data.define(:folder, :project_root, :state_file, :log_dir, :slug, :stage_name)

      TemplateBindings = Struct.new(
        :date, :items, :output_path, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      def initialize(cfg:, run_root: nil, logger: Logger.new($stderr))
        @cfg = cfg
        @run_root = run_root
        @logger = logger
      end

      def categorize(grouped, date:)
        output_path = File.join(run_dir(date), "items.json")
        prompt = render_prompt(grouped, date: date, output_path: output_path)
        task = runner_task(output_path: output_path, date: date)
        result = agent_for(task, prompt, output_path).run!
        self.class.parse_result!(result, output_path: output_path, grouped: grouped, logger: @logger)
      end

      def render_prompt(grouped, date:, output_path:)
        Hive::Stages::Base.render(
          "digest_prompt.md.erb",
          TemplateBindings.new(
            date: Window.parse_date(date),
            items: flat_items(grouped),
            output_path: output_path,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      class << self
        def parse_result!(result, output_path:, grouped:, logger: Logger.new($stderr))
          unless result.is_a?(Hash) && result[:status] == :ok
            raise ModelError, "digest categorizer failed: #{agent_error_message(result)}"
          end

          map_output_file(output_path, grouped: grouped, logger: logger)
        end

        def map_output_file(output_path, grouped:, logger: Logger.new($stderr))
          unless File.exist?(output_path) && File.size(output_path).positive?
            raise ModelError, "digest categorizer output missing or empty: #{output_path}"
          end

          doc = JSON.parse(File.read(output_path))
          map_document(doc, grouped: grouped, logger: logger)
        rescue JSON::ParserError => e
          raise ModelError, "digest categorizer output was not valid JSON: #{e.message}"
        end

        def map_document(doc, grouped:, logger: Logger.new($stderr))
          rows = doc.is_a?(Hash) ? doc["items"] : nil
          raise ModelError, "digest categorizer JSON must contain an items array" unless rows.is_a?(Array)

          by_id = rows.each_with_object({}) do |row, memo|
            next unless row.is_a?(Hash)

            id = row["id"].to_s
            memo[id] = row unless id.empty?
          end

          grouped.transform_values do |items|
            items.map { |item| categorized_item(item, by_id[item.categorizer_id], logger: logger) }
          end
        end

        private

        def agent_error_message(result)
          return result.inspect unless result.is_a?(Hash)

          result[:error_message] || result[:status] || result.inspect
        end

        def categorized_item(item, row, logger:)
          category = row && row["category"].to_s
          summary = row && row["summary"].to_s.strip
          if row.nil?
            log_warning(logger, "digest categorizer omitted item #{item.categorizer_id}; using default")
          elsif !VALID_CATEGORIES.include?(category)
            log_warning(logger, "digest categorizer returned invalid category #{category.inspect} " \
                                "for item #{item.categorizer_id}; using default")
          end

          category = DEFAULT_CATEGORY unless VALID_CATEGORIES.include?(category)
          summary = default_summary(item) if summary.to_s.empty?
          CategorizedItem.new(item: item, category: category, summary: summary)
        end

        def default_summary(item)
          title = item.pr_title.to_s.strip
          return title unless title.empty?

          item.display_label
        end

        def log_warning(logger, message)
          logger&.warn(message)
        end
      end

      private

      def flat_items(grouped)
        grouped.values.flatten
      end

      def run_dir(date)
        local_date = Window.parse_date(date)
        root = @run_root || File.join(Hive::Paths.state_home, "digest", "runs")
        dir = File.join(root, "#{local_date.iso8601}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(dir)
        dir
      end

      def runner_task(output_path:, date:)
        folder = File.dirname(output_path)
        RunnerTask.new(
          folder: folder,
          project_root: folder,
          state_file: File.join(folder, "state.yml"),
          log_dir: File.join(folder, "logs"),
          slug: "digest-#{Window.parse_date(date).iso8601}",
          stage_name: "digest"
        )
      end

      def agent_for(task, prompt, output_path)
        profile = Hive::AgentProfiles.lookup(agent_name, cfg: @cfg)
        Hive::Agent.new(
          task: task,
          prompt: prompt,
          profile: profile,
          add_dirs: [],
          cwd: task.folder,
          max_budget_usd: budget_usd,
          timeout_sec: timeout_sec,
          expected_output: output_path,
          status_mode: :output_file_exists,
          log_label: "digest",
          permission_mode: profile.name == :claude ? Hive::Config.claude_permission_mode(@cfg) : nil,
          cli_flags: profile.name == :claude ? Hive::Config.claude_cli_flags(@cfg) : []
        )
      end

      def agent_name
        @cfg.dig("digest", "agent") || @cfg.dig("patrol", "agent") || "claude"
      end

      def budget_usd
        @cfg.dig("budget_usd", "digest") || DEFAULT_BUDGET_USD
      end

      def timeout_sec
        @cfg.dig("timeout_sec", "digest") || DEFAULT_TIMEOUT_SEC
      end
    end
  end
end
