require "date"
require "fileutils"
require "json"
require "logger"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/config"
require "hive/digest/categories"
require "hive/digest/errors"
require "hive/digest/shipped_item"
require "hive/digest/window"
require "hive/paths"
require "hive/stages/base"

module Hive
  module Digest
    CategorizedItem = Data.define(:item, :category, :summary) do
      # Guard the type's invariants at the boundary so no caller can mint
      # an item with an unknown category (which the renderer would drop)
      # or a blank summary (which would render an empty changelog line).
      def initialize(item:, category:, summary:)
        unless Categories.valid?(category)
          raise ArgumentError, "digest category must be one of #{Categories::VALID.inspect}; got #{category.inspect}"
        end
        raise ArgumentError, "digest summary must not be blank" if summary.to_s.strip.empty?

        super
      end
    end

    class Categorizer
      DEFAULT_CATEGORY = Categories::DEFAULT
      DEFAULT_BUDGET_USD = 50
      DEFAULT_TIMEOUT_SEC = 1800
      # Keep roughly this many per-run scratch dirs under
      # <state_home>/digest/runs. Transiently RETENTION + 1: prune_old_runs
      # runs before the current run's dir is created, so the new dir is the
      # (RETENTION + 1)th until the next run prunes back down.
      RUN_DIR_RETENTION = 20

      RunnerTask = Data.define(:folder, :state_file, :log_dir, :slug, :stage_name)

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
      rescue SystemCallError => e
        # A broken digest.agent config (a missing/misnamed binary raises
        # Errno::ENOENT straight from Process.spawn — Agent#run! does not
        # rescue it) or a scratch-dir disk fault (mkdir_p in run_dir) raises a
        # SystemCallError that would otherwise escape Hive::Digest.run's
        # ModelError-only rescue: the user would get NO "digest failed" notice,
        # only a stderr/daemon-event trace, so a persistent agent-config typo
        # would silently never deliver. Convert agent spawn/run + scratch-dir
        # failures to ModelError so the existing failed-notice path fires.
        # Scoped to SystemCallError on purpose — parse/output failures already
        # raise ModelError via parse_result!, and a blanket StandardError
        # rescue would mask genuine bugs as a benign "digest failed".
        @logger&.error("digest categorizer agent run failed: #{e.class}: #{e.message}")
        raise ModelError, "digest categorizer could not run the agent: #{e.class}: #{e.message}"
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
            raise_model_error("digest categorizer failed: #{agent_error_message(result)}",
                              output_path: output_path, logger: logger)
          end

          map_output_file(output_path, grouped: grouped, logger: logger)
        end

        def map_output_file(output_path, grouped:, logger: Logger.new($stderr))
          unless File.exist?(output_path) && File.size(output_path).positive?
            raise_model_error("digest categorizer output missing or empty: #{output_path}",
                              output_path: output_path, logger: logger)
          end

          doc = JSON.parse(File.read(output_path))
          map_document(doc, grouped: grouped, logger: logger)
        rescue JSON::ParserError => e
          raise_model_error("digest categorizer output was not valid JSON: #{e.message}",
                            output_path: output_path, logger: logger)
        end

        def map_document(doc, grouped:, logger: Logger.new($stderr))
          rows = doc.is_a?(Hash) ? doc["items"] : nil
          unless rows.is_a?(Array)
            raise ModelError, "digest categorizer JSON must contain an items array"
          end

          by_id = rows.each_with_object({}) do |row, memo|
            next unless row.is_a?(Hash)

            id = row["id"].to_s
            next if id.empty?

            # Last-write-wins on a duplicate id silently drops the first
            # row's category/summary. Combined with attacker-influenceable
            # PR text this is steerable, so surface it rather than swallow.
            if memo.key?(id)
              log_warning(logger, "digest categorizer returned a duplicate id #{id.inspect}; " \
                                  "using the last occurrence")
            end
            memo[id] = row
          end

          grouped.transform_values do |items|
            items.map { |item| categorized_item(item, by_id[item.categorizer_id], logger: logger) }
          end
        end

        private

        # Raise a ModelError whose message names the run dir and its log
        # dir, and mirror it to the operator log, so a failed digest is
        # debuggable without hunting for the scratch folder. The
        # user-facing Telegram notice stays short (see Renderer.failed).
        def raise_model_error(message, output_path:, logger:)
          run_dir = File.dirname(output_path.to_s)
          detailed = "#{message} (run dir: #{run_dir}; logs: #{File.join(run_dir, 'logs')})"
          logger&.error(detailed)
          raise ModelError, detailed
        end

        def agent_error_message(result)
          return result.inspect unless result.is_a?(Hash)

          result[:error_message] || result[:status] || result.inspect
        end

        def categorized_item(item, row, logger:)
          category = row && row["category"].to_s
          summary = row && row["summary"].to_s.strip
          # Single source of validity (Categories.valid?) shared with the
          # CategorizedItem boundary guard, so the default-and-warn path
          # here can't drift from what the type accepts.
          category_valid = Categories.valid?(category)
          if row.nil?
            log_warning(logger, "digest categorizer omitted item #{item.categorizer_id}; using default")
          elsif !category_valid
            log_warning(logger, "digest categorizer returned invalid category #{category.inspect} " \
                                "for item #{item.categorizer_id}; using default")
          end

          category = DEFAULT_CATEGORY unless category_valid
          summary = default_summary(item) if summary.to_s.empty?
          CategorizedItem.new(item: item, category: category, summary: summary)
        end

        def default_summary(item)
          title = item.pr_title.to_s.strip
          return title unless title.empty?

          item.display_label
        end

        def log_warning(logger, message)
          # Fall back to $stderr when no logger is wired so the "model
          # omitted / miscategorized an item — using default" signal can't
          # be silently configured away: a half-bad model run would
          # otherwise produce a plausible digest with no operator trace.
          if logger
            logger.warn(message)
          else
            Kernel.warn(message)
          end
        end
      end

      private

      def flat_items(grouped)
        grouped.values.flatten
      end

      def run_dir(date)
        local_date = Window.parse_date(date)
        root = @run_root || File.join(Hive::Paths.state_home, "digest", "runs")
        FileUtils.mkdir_p(root)
        prune_old_runs(root)
        dir = File.join(root, "#{local_date.iso8601}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(dir)
        dir
      end

      # Bound the per-run scratch dirs (items.json / state.yml / logs):
      # they would otherwise accumulate one folder per day forever. Keep
      # the most recent RUN_DIR_RETENTION by mtime and drop the rest.
      def prune_old_runs(root)
        dirs = Dir.children(root)
                  .map { |name| File.join(root, name) }
                  .select { |path| File.directory?(path) }
        return if dirs.size <= RUN_DIR_RETENTION

        dirs.sort_by { |path| File.mtime(path) }
            .first(dirs.size - RUN_DIR_RETENTION)
            .each { |path| FileUtils.rm_rf(path) }
      rescue SystemCallError => e
        @logger&.warn("digest: run-dir prune failed under #{root}: #{e.message}")
      end

      def runner_task(output_path:, date:)
        folder = File.dirname(output_path)
        RunnerTask.new(
          folder: folder,
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
