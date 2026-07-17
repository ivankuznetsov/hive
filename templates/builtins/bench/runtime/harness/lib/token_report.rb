# frozen_string_literal: true

require "json"
require "lib/pricing"

module HiveBench
  # Per-MODEL token accounting for one cell, from the agent stream logs. Every
  # usage event is attributed to the model that produced it — from the event's
  # own model id when the stream carries one (claude, pi), else from the stage
  # the log belongs to and the candidate's stage->model map (codex events carry
  # usage but no model id). This is what makes mixed candidates priceable:
  # attribution is per event, not per cell.
  #
  # Three stream schemas:
  #   claude: input_tokens / output_tokens / cache_read_input_tokens /
  #           cache_creation_input_tokens; model at message.model.
  #           input_tokens EXCLUDES cache reads.
  #   pi:     input / output / cacheRead / cacheWrite; model on the same object.
  #   codex:  input_tokens / cached_input_tokens / output_tokens
  #           (+ reasoning_output_tokens as a detail of output); NO model id.
  #           input_tokens INCLUDES cached_input_tokens (OpenAI convention).
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

          model = obj["model"] || obj.dig("message", "model") || stage_models[stage] || "unknown"
          next if model == "<synthetic>"

          add_usage(per_model[model], usage)
        end
      end
      per_model
    end

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
