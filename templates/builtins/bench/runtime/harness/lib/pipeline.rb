# frozen_string_literal: true

require "fileutils"
require "lib/git_restore"
require "lib/isolation_exec"
require "lib/agent_limit"

module HiveBench
  # Planner/executor pipeline: a planner agent authors the plan from the full
  # hive ideation context (idea + brainstorm + any screenshots + the repo) — it
  # is NOT handed the frozen plan, it must write its own — then an executor agent
  # implements THAT plan in a fresh checkout. The pair is one contestant cell,
  # judged on the executor's final diff. This is the real e2e workflow (idea ->
  # plan -> execute); the frozen-plan Run is execute-only. The executor gets the
  # plan only (same framing as the frozen-plan executor), so the sole variable vs
  # a frozen-plan run is WHOSE plan. When planner == executor (self-plan), the
  # cell measures one agent's full capability — e.g. codex-only = codex plans too.
  #
  #   plan_spawn / exec_spawn: Run-style spawn seams. plan_spawn must use an
  #   identity prompt frame (the pipeline supplies the full planner prompt);
  #   exec_spawn uses the normal executor frame. Both are isolated gen runs.
  class Pipeline
    Cell = Data.define(:task_id, :agent_id, :mode, :model_version, :status, :diff_path, :telemetry, :reason)

    def initialize(plan_spawn:, exec_spawn:, restorer: GitRestore.new, clock: -> { Time.now.utc })
      @restorer = restorer
      @plan_spawn = plan_spawn
      @exec_spawn = exec_spawn
      @clock = clock
    end

    # planner/executor: HiveBench::Profile. pair_id: the agent_id recorded (e.g.
    # "glm-5.2->kimi-k2.7"). Returns a Cell shaped like Run::Cell for scoring.
    def call(entry:, planner:, executor:, pair_id:, out_dir:)
      FileUtils.mkdir_p(out_dir)
      base = entry.dig("source", "base_commit") or raise ArgumentError, "entry has no source.base_commit"
      source = entry["checkout_source"] or raise ArgumentError, "entry has no checkout_source"

      plan, plan_tel, plan_result = plan_phase(entry, planner, source, base, out_dir)
      return parked(entry, pair_id, planner, "planner hit a provider limit") if limit?(plan_result)
      if plan.strip.empty?
        return cell(entry, pair_id, executor, "plan_failed", nil, plan_tel,
                    "planner wrote no #{IsolationExec::PLAN_OUTPUT_FILE}")
      end

      diff_path, exec_tel, exec_result, status = exec_phase(plan, executor, source, base, out_dir)
      return parked(entry, pair_id, executor, "executor hit a provider limit") if limit?(exec_result)

      cell(entry, pair_id, executor, status, diff_path, merge_telemetry(plan_tel, exec_tel),
           status == "agent_failed" ? "executor exited non-zero" : nil)
    end

    private

    def plan_phase(entry, planner, source, base, out_dir)
      work = File.join(out_dir, "plan_work")
      @restorer.restore(source: source, base_commit: base, into: work)
      idea = read_entry(entry, entry.dig("spec", "idea"))
      brainstorm = read_entry(entry, entry.dig("spec", "brainstorm"))
      assets = stage_assets(entry, work)
      prompt = IsolationExec.frame_plan_prompt(idea, brainstorm, assets: assets)
      started = @clock.call
      result = @plan_spawn.call(profile: planner, prompt: prompt, cwd: work)
      tel = phase_telemetry("planner", result, started, @clock.call)
      plan_file = File.join(work, IsolationExec::PLAN_OUTPUT_FILE)
      plan = File.file?(plan_file) ? File.read(plan_file) : ""
      [plan, tel, result]
    end

    def exec_phase(plan, executor, source, base, out_dir)
      work = File.join(out_dir, "work")
      @restorer.restore(source: source, base_commit: base, into: work)
      started = @clock.call
      result = @exec_spawn.call(profile: executor, prompt: plan, cwd: work)
      tel = phase_telemetry("executor", result, started, @clock.call)
      diff = @restorer.diff(work_dir: work, base_commit: base)
      diff_path = File.join(out_dir, "candidate.patch")
      File.write(diff_path, diff)
      [diff_path, tel, result, generation_status(result[:status], diff)]
    end

    def generation_status(spawn_status, diff)
      case spawn_status
      when :ok then diff.strip.empty? ? "empty_diff" : "generated"
      when :timeout then "timed_out"
      else "agent_failed"
      end
    end

    def limit?(result)
      stream = result.key?(:provider_errors) ? result[:provider_errors].to_s : "#{result[:stdout]}\n#{result[:stderr]}"
      AgentLimit.limit_hit?(stream)
    end

    def phase_telemetry(phase, result, started, ended)
      usage = result[:usage] || {}
      { "#{phase}_wall_clock_sec" => (ended - started).round(2),
        "#{phase}_input_tokens" => usage[:input], "#{phase}_output_tokens" => usage[:output],
        "#{phase}_cost_usd" => usage[:cost] }.compact
    end

    # Pipeline efficiency = planner + executor; wall_clock_sec / cost_usd are the
    # summed totals the leaderboard reads, with per-phase breakdown retained.
    def merge_telemetry(plan_tel, exec_tel)
      total = plan_tel.merge(exec_tel)
      total["wall_clock_sec"] = (plan_tel["planner_wall_clock_sec"].to_f + exec_tel["executor_wall_clock_sec"].to_f).round(2)
      cost = [plan_tel["planner_cost_usd"], exec_tel["executor_cost_usd"]].compact
      total["cost_usd"] = cost.sum.round(6) unless cost.empty?
      total
    end

    def cell(entry, pair_id, executor, status, diff_path, telemetry, reason)
      Cell.new(task_id: entry.fetch("task_id"), agent_id: pair_id, mode: "pipeline",
               model_version: executor.model, status: status, diff_path: diff_path,
               telemetry: telemetry, reason: reason)
    end

    def parked(entry, pair_id, profile, reason)
      Cell.new(task_id: entry.fetch("task_id"), agent_id: pair_id, mode: "pipeline",
               model_version: profile.model, status: "limit_hit", diff_path: nil, telemetry: {}, reason: reason)
    end

    def read_entry(entry, rel)
      return "" if rel.nil?

      path = File.join(entry.fetch("entry_dir"), rel)
      File.file?(path) ? File.read(path) : ""
    end

    # Copy the task's spec screenshots into the planner's checkout so the idea's
    # `assets/<file>` references resolve and the agent can open them — the visual
    # half of the spec a human had. Staged only in plan_work (the planner's tree),
    # never in the executor's, so the scored diff stays clean. Returns the in-repo
    # relative paths for the prompt. No-op when the task ships no assets.
    def stage_assets(entry, work)
      src = File.join(entry.fetch("entry_dir"), "spec", "assets")
      return [] unless File.directory?(src)

      dest = File.join(work, "assets")
      FileUtils.mkdir_p(dest)
      Dir.children(src).sort.filter_map do |f|
        next unless File.file?(File.join(src, f))

        FileUtils.cp(File.join(src, f), File.join(dest, f))
        "assets/#{f}"
      end
    end
  end
end
