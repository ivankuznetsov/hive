# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "lib/git_restore"
require "lib/agent_limit"

module HiveBench
  # Runs one benchmark cell = (corpus task, candidate agent) and produces the
  # cell's diff + telemetry, ready for scoring (U4). Two modes:
  #
  #   reused — the cell's agent is the task's original producer at a compatible
  #            model version, so the diff is the held-out reference and cost /
  #            fix-passes come from existing hive data. wall_clock is N/A (the
  #            original run wasn't timed for the bench). Tagged "reused".
  #   fresh  — restore the repo at base_commit, run the candidate from the frozen
  #            plan, capture the diff + telemetry. Tagged "fresh".
  #
  # Generation and evaluation are separated: this unit persists the diff and
  # stops. Scoring (gate + judge) is U4 — so an infra failure never forces an
  # expensive re-run of the agent.
  #
  # External effects are seams:
  #   restorer:       GitRestore (real git, hardened)
  #   spawn:          ->(profile:, prompt:, cwd:) => { stdout:, stderr:, status:, model:, usage: }
  #                   (in production: IsolationExec.gen_exec runs the candidate
  #                    inside isolation.sh `gen` mode — --read-only + caps, with
  #                    default-bridge egress gated on HB_ALLOW_EGRESS=1 and
  #                    allowlisted by the CI firewall layer; see Dockerfile.runner)
  #   reuse_resolver: ->(entry, profile) => { diff:, model_version:, telemetry: }|nil
  class Run
    Cell = Data.define(:task_id, :agent_id, :mode, :model_version, :status, :diff_path, :telemetry, :reason)

    def initialize(restorer: GitRestore.new, spawn: nil, reuse_resolver: ->(_e, _p) {},
                   clock: -> { Time.now.utc })
      @restorer = restorer
      @spawn = spawn
      @reuse_resolver = reuse_resolver
      @clock = clock
    end

    # entry: a loaded manifest hash (from a corpus entry) augmented with
    #   "entry_dir" (where spec/, reference.patch live) and "source" path.
    # profile: a HiveBench::Profile.
    # out_dir: where to persist this cell's artifacts.
    def call(entry:, profile:, out_dir:)
      task_id = entry.fetch("task_id")
      FileUtils.mkdir_p(out_dir)

      if (reused = @reuse_resolver.call(entry, profile))
        return persist_reused(task_id, profile, reused, out_dir)
      end

      run_fresh(entry, profile, task_id, out_dir)
    end

    private

    def persist_reused(task_id, profile, reused, out_dir)
      diff_path = File.join(out_dir, "candidate.patch")
      File.write(diff_path, reused.fetch(:diff))
      telemetry = { "wall_clock_sec" => nil }.merge(reused[:telemetry] || {})
      cell(task_id, profile, mode: "reused", status: "generated",
                             model_version: reused[:model_version] || profile.model,
                             diff_path: diff_path, telemetry: telemetry, reason: "reused recorded producer output")
    end

    def run_fresh(entry, profile, task_id, out_dir)
      raise ArgumentError, "fresh run needs a spawn seam" unless @spawn

      work = File.join(out_dir, "work")
      source = entry["checkout_source"] or raise ArgumentError, "entry has no checkout_source (clone path/URL)"
      @restorer.restore(source: source, base_commit: base_commit(entry), into: work)

      prompt = File.read(File.join(entry.fetch("entry_dir"), entry.dig("spec", "plan")))
      started = @clock.call
      result = @spawn.call(profile: profile, prompt: prompt, cwd: work)
      ended = @clock.call

      # Prefer a focused provider-error signal when the spawn isolates one (pi
      # gen_exec does): scanning the agent's full solution prose would let a
      # throttling-themed task false-positive into limit_hit and park a success.
      # Fall back to the whole stream for spawns that report no structured errors.
      stream = result.key?(:provider_errors) ? result[:provider_errors].to_s : "#{result[:stdout]}\n#{result[:stderr]}"
      if AgentLimit.limit_hit?(stream)
        return cell(task_id, profile, mode: "fresh", status: "limit_hit",
                                      model_version: result[:model] || profile.model, diff_path: nil,
                                      telemetry: {}, reason: "provider usage/credit limit — re-run after cooldown")
      end

      # Persist the diff BEFORE any scoring (generation/evaluation split).
      diff = @restorer.diff(work_dir: work, base_commit: base_commit(entry))
      diff_path = File.join(out_dir, "candidate.patch")
      File.write(diff_path, diff)

      status = generation_status(result[:status], diff)
      cell(task_id, profile, mode: "fresh", status: status,
                             model_version: result[:model] || profile.model, diff_path: diff_path,
                             telemetry: fresh_telemetry(result, started, ended),
                             reason: failure_reason(status, result))
    end

    # Clean exit -> empty_diff/generated; a timeout-kill or a non-zero exit keep
    # the partial diff but carry a distinct status so a truncated run is never
    # recorded as if it finished.
    def generation_status(spawn_status, diff)
      case spawn_status
      when :ok then diff.strip.empty? ? "empty_diff" : "generated"
      when :timeout then "timed_out"
      else "agent_failed"
      end
    end

    # A short, debuggable trace of WHY a fresh run did not finish cleanly.
    def failure_reason(status, result)
      case status
      when "timed_out" then "agent did not finish within HB_AGENT_TIMEOUT (partial diff kept)"
      when "agent_failed" then failure_snippet(result)
      end
    end

    def failure_snippet(result)
      diag = result[:stderr].to_s.strip
      diag = result[:stdout].to_s.strip if diag.empty?
      "agent exited non-zero: #{diag[0, 300]}"
    end

    def fresh_telemetry(result, started, ended)
      usage = result[:usage] || {}
      {
        "wall_clock_sec" => (ended - started).round(2),
        "input_tokens" => usage[:input],
        "output_tokens" => usage[:output],
        "cached_tokens" => usage[:cached],
        # Pay-per-token providers (OpenRouter, via pi) report the run's real cost
        # in the usage stream — ground truth, so we record it directly. Subscription
        # agents that report no cost leave this nil (a price table can fill it later).
        "cost_usd" => usage[:cost]
      }.compact
    end

    def base_commit(entry)
      entry.dig("source", "base_commit") or raise ArgumentError, "entry has no source.base_commit"
    end

    def cell(task_id, profile, mode:, status:, model_version:, diff_path:, telemetry:, reason:)
      Cell.new(task_id: task_id, agent_id: profile.id, mode: mode, model_version: model_version,
               status: status, diff_path: diff_path, telemetry: telemetry, reason: reason)
    end
  end
end
