# frozen_string_literal: true

require "json"
require "sqlite3"
require "lib/pricing"

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
  #             normalized per-session values live in .hb/hive-home/usage.db.
  module TokenReport
    module_function

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
      # omits the provider event payloads from persisted logs. Replace a bucket
      # with the DB aggregate instead of adding it, so a future unredacted log
      # cannot double-count the same OpenCode sessions.
      scan_usage_db(target_dir).each { |model, usage| per_model[model] = usage }
      per_model
    end

    def scan_usage_db(target_dir)
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
      !row.key?(availability) || row[availability].to_i == 1
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
