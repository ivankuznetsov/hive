# frozen_string_literal: true

require "json"
require "sqlite3"
require "securerandom"

module HiveBench
  # Per-MODEL token accounting for one cell, from the agent stream logs. Every
  # usage event is attributed to the model that produced it — from the event's
  # own model id when the stream carries one (claude, pi), else from the stage
  # the log belongs to and the candidate's stage->model map (codex events carry
  # usage but no model id). This is what makes mixed candidates priceable:
  # attribution is per event, not per cell.
  #
  # Three stream schemas plus Hive's structured usage database:
  #   claude: input_tokens / output_tokens / cache_read_input_tokens /
  #           cache_creation_input_tokens; model at message.model.
  #           input_tokens EXCLUDES cache reads.
  #   pi:     input / output / cacheRead / cacheWrite at message.usage on each
  #           assistant message_end; model at message.model.
  #   codex:  input_tokens / cached_input_tokens / output_tokens
  #           (+ reasoning_output_tokens as a detail of output); NO model id.
  #           input_tokens INCLUDES cached_input_tokens (OpenAI convention).
  #   OpenCode: raw events are deliberately redacted from Hive logs; the
  #             normalized sessions live in the controller runtime database.
  #             The controller exports only model/token aggregates to receipts;
  #             historical cells can still use .hb/hive-home/usage.db.
  module TokenReport
    module_function

    class UsageUnavailable < StandardError; end
    EXPORT_SCHEMA = "hive-bench-opencode-usage.v1"
    BUCKETS = %w[input output cache_read cache_write].freeze

    # Stage prefix of a log filename -> which candidate stage ran it.
    STAGE_OF = { "plan" => :plan, "execute" => :execute, "review" => :review,
                 "open" => :review, "artifacts" => :review }.freeze

    # stage_models: { plan: "<model-id>", execute: "...", review: "..." } — the
    # fallback attribution for streams without per-event model ids.
    def scan_cell(target_dir, stage_models: {})
      per_model = Hash.new { |h, k| h[k] = Hash.new(0) }
      Dir.glob(File.join(target_dir, ".hive-state", "logs", "**", "*.log")).each do |log|
        stage = STAGE_OF[File.basename(log).split("-").first]
        File.foreach(log) do |line|
          brace = line.index("{") or next
          obj = begin
            JSON.parse(line[brace..])
          rescue JSON::ParserError
            next
          end
          # "result" events carry the SESSION-CUMULATIVE usage (double-counts
          # every turn already summed) and "system" events carry progress
          # counters (total_tokens), not billing buckets — both are skipped.
          next if %w[result system].include?(obj["type"])

          usage = obj["usage"] || obj.dig("message", "usage")
          next unless usage.is_a?(Hash)
          # Pi repeats the same in-progress/cumulative usage on message_update
          # and turn_end. Each assistant message_end is one billable model
          # response; summing the other event copies inflates every Pi-backed
          # candidate by roughly four times.
          if usage.key?("cacheRead") || usage.key?("input")
            next unless obj["type"] == "message_end" && obj.dig("message", "role") == "assistant"
          end

          model = obj["model"] || obj.dig("message", "model") || stage_models[stage] || "unknown"
          next if model == "<synthetic>"

          add_usage(per_model[model], usage)
        end
      end
      # The database is authoritative for OpenCode because Hive intentionally
      # omits the provider event payloads from persisted logs. Other harnesses
      # can use that same model, so preserve their stream usage when merging.
      scan_usage_db(target_dir).each do |model, usage|
        BUCKETS.each { |key| per_model[model][key] += usage.fetch(key, 0) }
      end
      per_model
    end

    def scan_usage_db(target_dir)
      exported = scan_usage_export(target_dir)
      return exported unless exported.nil?

      path = File.join(target_dir, ".hb", "hive-home", "usage.db")
      return {} unless File.file?(path)

      database = SQLite3::Database.new(path)
      database.results_as_hash = true
      columns = database.execute("PRAGMA table_info(token_usage)").map { |row| row["name"] }
      return {} unless %w[agent model input output cached].all? { |name| columns.include?(name) }

      rows = database.execute("SELECT * FROM token_usage WHERE agent = ?", "opencode")
      per_model = Hash.new { |hash, model| hash[model] = Hash.new(0) }
      rows.each do |row|
        model = usage_model(row)
        acc = per_model[model]
        acc["input"] += available_value(row, "input")
        acc["output"] += available_value(row, "output")
        acc["cache_read"] += if available?(row, "cache_read")
                               row["cache_read"].to_i
                             else
                               available_value(row, "cached")
                             end
        acc["cache_write"] += available_value(row, "cache_write")
      end
      per_model
    rescue SQLite3::Exception
      {}
    ensure
      database&.close
    end

    # Runs in the controller, while its private runtime database is accessible.
    # Export only billing buckets and model attribution, never session payloads,
    # task text, credentials, or the database itself. Each retry emits a new
    # cumulative receipt; readers select one receipt rather than summing them.
    def export_opencode_usage(directory, task_slug:)
      require "hive/usage_db"
      rows = Hive::UsageDb.database.read do |db|
        db[:token_usage].where(agent: "opencode", project_slug: "work", task_slug: task_slug)
          .select(:model, :actual_backend, :actual_model, :input, :output, :cached,
                  :cache_read, :cache_write, :input_available, :output_available,
                  :cached_available, :cache_read_available, :cache_write_available,
                  :input_includes_cache_read, :input_includes_cache_write).all
      end
      models = Hash.new { |hash, model| hash[model] = BUCKETS.to_h { |key| [key, 0] } }
      rows.each do |record|
        row = record.transform_keys(&:to_s)
        raise UsageUnavailable, "OpenCode token buckets unavailable" unless available?(row, "input") && available?(row, "output")

        cache_read = available?(row, "cache_read") ? available_value(row, "cache_read") : available_value(row, "cached")
        cache_write = available_value(row, "cache_write")
        input = available_value(row, "input")
        input -= cache_read if row["input_includes_cache_read"] == true || row["input_includes_cache_read"] == 1
        input -= cache_write if row["input_includes_cache_write"] == true || row["input_includes_cache_write"] == 1
        values = { "input" => [input, 0].max, "output" => available_value(row, "output"),
                   "cache_read" => cache_read, "cache_write" => cache_write }
        values.each { |key, value| models[usage_model(row)][key] += value }
      end
      write_usage_export(directory, "schema" => EXPORT_SCHEMA, "status" => "available", "models" => models)
    rescue StandardError => error
      write_usage_export(directory, "schema" => EXPORT_SCHEMA, "status" => "unavailable", "reason" => error.class.name)
      raise UsageUnavailable, "controller OpenCode usage export unavailable (#{error.class})"
    end

    def write_usage_export(directory, payload)
      name = "opencode-usage-%020d-%s.json" % [Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond), SecureRandom.uuid]
      path = File.join(directory, name)
      temporary = "#{path}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload))
        file.flush
        file.fsync
        file.chmod(0o444)
      end
      File.rename(temporary, path)
      path
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end
    private_class_method :write_usage_export

    def scan_usage_export(target_dir)
      directory = File.join(File.dirname(File.expand_path(target_dir)), "usage-export")
      return nil unless File.directory?(directory)

      path = Dir.glob(File.join(directory, "opencode-usage-*.json")).max
      raise UsageUnavailable, "controller OpenCode usage receipt missing" unless path

      receipt = JSON.parse(File.read(path))
      unless receipt["schema"] == EXPORT_SCHEMA && receipt["status"] == "available" && receipt["models"].is_a?(Hash)
        raise UsageUnavailable, "controller OpenCode usage receipt unavailable"
      end
      receipt["models"].each do |model, buckets|
        unless model.is_a?(String) && buckets.is_a?(Hash) && buckets.keys.sort == BUCKETS.sort &&
               buckets.values.all? { |value| value.is_a?(Integer) && value >= 0 }
          raise UsageUnavailable, "controller OpenCode usage receipt invalid"
        end
      end
      receipt["models"]
    rescue JSON::ParserError
      raise UsageUnavailable, "controller OpenCode usage receipt malformed"
    end
    private_class_method :scan_usage_export

    def usage_model(row)
      model = row["model"].to_s
      return model unless model.empty?

      backend = row["actual_backend"].to_s
      actual = row["actual_model"].to_s
      route = [backend, actual].reject(&:empty?).join("/")
      route.empty? ? "unknown" : route
    end
    private_class_method :usage_model

    def available?(row, bucket)
      availability = "#{bucket}_available"
      row.key?(bucket) && (!row.key?(availability) || row[availability].to_i == 1)
    end
    private_class_method :available?

    def available_value(row, bucket)
      available?(row, bucket) ? row[bucket].to_i : 0
    end
    private_class_method :available_value

    def add_usage(acc, usage)
      if usage.key?("cacheRead") || usage.key?("input") # pi
        acc["input"] += usage["input"].to_i
        acc["output"] += usage["output"].to_i
        acc["cache_read"] += usage["cacheRead"].to_i
        acc["cache_write"] += usage["cacheWrite"].to_i
      elsif usage.key?("cached_input_tokens") # codex: input INCLUDES cached
        cached = usage["cached_input_tokens"].to_i
        acc["input"] += [usage["input_tokens"].to_i - cached, 0].max
        acc["output"] += usage["output_tokens"].to_i
        acc["cache_read"] += cached
      else # claude: input EXCLUDES cache reads
        acc["input"] += usage["input_tokens"].to_i
        acc["output"] += usage["output_tokens"].to_i
        acc["cache_read"] += usage["cache_read_input_tokens"].to_i
        acc["cache_write"] += usage["cache_creation_input_tokens"].to_i
      end
    end

    # { model => tokens } -> { model => { "tokens" => ..., "cost_usd" => ... } }
    # plus "_total". An unpriceable model keeps its tokens with cost nil, and
    # makes the cell total nil too — a partial total would read as complete.
    def price(per_model)
      # The sealed controller mounts this exporter without pricing's model
      # catalog. Exporting native token buckets must not depend on that catalog.
      require "lib/pricing"
      out = per_model.to_h do |model, t|
        cost = Pricing.estimate_usd(model_strings: [model], input: t["input"], output: t["output"],
                                    cached: t["cache_read"], cache_creation: t["cache_write"])
        [model, { "tokens" => t.dup, "cost_usd" => cost }]
      end
      total_tokens = Hash.new(0)
      per_model.each_value { |t| BUCKETS.each { |b| total_tokens[b] += t[b] } }
      costs = out.values.map { |v| v["cost_usd"] }
      out["_total"] = { "tokens" => total_tokens,
                        "cost_usd" => costs.any?(&:nil?) ? nil : costs.sum.round(4) }
      out
    end
  end
end
