# frozen_string_literal: true

require "open3"
require "English"
require "fileutils"
require "tempfile"
require "json"

module HiveBench
  # Bridges the harness's exec/spawn seams to the real isolated runner
  # (isolation.sh). Kept small and separate so Gate/Run stay pure/testable and
  # only the edge touches Docker.
  #
  #   gate_exec -> Gate's `exec` seam: --network none command, no agent/model.
  #   gen_exec  -> Run's `spawn` seam: runs the candidate agent (pi) against the
  #                restored repo with model-API egress, and reports token usage.
  module IsolationExec
    # Raised when the runner could not establish isolation. Per the integrity
    # model, a score is never produced from an un-isolated run — so this aborts
    # the cell loudly rather than letting a bad cell be scored. RunAll parks it.
    class IsolationError < StandardError; end

    # Raised when a cell's harness has no wired gen path yet (claude/codex). An
    # ArgumentError subtype because it signals a wrong-input/config condition;
    # RunAll's fail-soft rescue parks the cell rather than crashing the pass.
    class UnsupportedHarness < ArgumentError; end

    module_function

    SCRIPT = File.expand_path("isolation.sh", __dir__)
    # isolation.sh exits with this when isolation cannot be enforced (no docker,
    # egress not acknowledged, unresolvable work dir, …).
    FAIL_ISOLATION = 70
    # docker run's own "container never started" codes: 125 (daemon/flag/mount
    # error), 126 (entrypoint not executable), 127 (command/image bin missing).
    # The agent never ran, so these are isolation/infra failures, NOT an agent
    # failure — blaming the candidate for a broken runner would corrupt scores.
    CONTAINER_START_FAILURES = [125, 126, 127].freeze
    # The `timeout` wrapper returns this when it kills an agent that ran past
    # HB_AGENT_TIMEOUT — distinct from a clean failure so a truncated run is
    # never recorded as if it finished.
    AGENT_TIMEOUT_EXIT = 124
    # The frozen plan is delivered to the agent as a file inside /work and passed
    # as a positional message via "$(cat ...)" — content is forwarded verbatim
    # (no shell re-expansion of backticks/$/quotes the plan may contain).
    PROMPT_FILE = ".hive-bench-prompt.md"
    # In planner/executor pipeline mode the planner writes its plan to this file
    # in the repo root; the pipeline reads it and feeds it to the executor.
    PLAN_OUTPUT_FILE = "HIVE_BENCH_PLAN.md"
    # Wall-clock ceiling for a single candidate run (seconds); a wedged agent
    # exits the container instead of hanging the whole pass. Operator-overridable
    # via HB_AGENT_TIMEOUT. Set high (2h) because slower open models (glm) need
    # room to finish a multi-file plan — a too-low ceiling scores truncated work.
    DEFAULT_AGENT_TIMEOUT = 7200

    # Returns a gate-exec proc: ->(cmd:, work_dir:) => { output:, ok: }.
    # `script` is injectable so the seam is testable without real Docker.
    def gate_exec(script: SCRIPT)
      lambda do |cmd:, work_dir:|
        out, status = Open3.capture2e("bash", script, "gate", work_dir, cmd)
        fail_closed!(status, out, phase: "gate")
        { output: out, ok: status.success? }
      end
    end

    # Returns a gen-spawn proc matching Run's seam:
    #   ->(profile:, prompt:, cwd:) => { stdout:, stderr:, status:, model:, usage: }
    # The candidate agent runs inside isolation.sh gen mode; its JSON stream is
    # parsed for token usage + provider cost. Generation and scoring stay split:
    # this only produces the stream/usage — the diff is captured by the runner.
    # `frame` wraps the prompt before delivery — defaults to the executor framing;
    # the pipeline passes an identity frame so it can supply a full planner prompt.
    def gen_exec(script: SCRIPT, frame: method(:frame_prompt))
      lambda do |profile:, prompt:, cwd:|
        prompt_path = File.join(cwd, PROMPT_FILE)
        begin
          File.write(prompt_path, frame.call(prompt))
          cmd = agent_command(profile)
          # HB_ALLOW_EGRESS acknowledges the run permits model-API egress; provider
          # keys are inherited from the driver's env, and a claude cell's OAuth
          # creds path is passed so isolation.sh mounts it read-only.
          # Capture to files, not pipes: agent JSON streams reach many MB and
          # Open3.capture3's reader threads race ("stream closed in another
          # thread") on that volume — file redirection sidesteps it entirely.
          out, err, status = run_to_files(gen_env(profile), script, cwd, cmd)
          fail_closed!(status, err, phase: "gen")
          parsed = parse_stream(profile.harness, out)
          # A clean exit that yielded no parseable usage usually means the agent's
          # JSON schema drifted — a paid run would otherwise be recorded silently
          # free. Surface it (don't fail: a no-op run legitimately has no usage).
          if status.success? && parsed[:usage].empty?
            warn "hive-bench: gen produced no parseable usage (#{profile.harness} JSON schema drift?)"
          end
          { stdout: out, stderr: err, status: run_status(status),
            model: parsed[:model] || profile.model, usage: parsed[:usage],
            # The focused limit signal: provider error messages + stderr only,
            # NOT the agent's solution prose (which on a throttling-themed task
            # would false-positive AgentLimit and wrongly park a success).
            provider_errors: "#{parsed[:errors].join("\n")}\n#{err}" }
        ensure
          FileUtils.rm_f(prompt_path)
        end
      end
    end

    # :ok (clean), :timeout (killed at the wall-clock ceiling — partial work), or
    # :error (the agent ran and exited non-zero). The caller keeps the partial
    # diff for :timeout/:error but records the distinct status.
    def run_status(status)
      return :timeout if status.exitstatus == AGENT_TIMEOUT_EXIT
      return :ok if status.success?

      :error
    end

    # Fail closed on an explicit isolation refusal (70) or a container that never
    # started (125-127). Other non-zero exits mean the agent ran and failed, or
    # the gate's tests failed — those are scored normally, not raised.
    def fail_closed!(status, diagnostics, phase:)
      code = status.exitstatus
      return unless code == FAIL_ISOLATION || CONTAINER_START_FAILURES.include?(code)

      raise IsolationError, "runner could not establish isolation (#{phase}, exit #{code}): #{diagnostics.to_s.strip[0, 300]}"
    end

    # The env the runner inherits for a gen cell. claude needs its OAuth creds
    # bind-mounted (path only — never the token value), set per harness.
    def gen_env(profile)
      env = { "HB_ALLOW_EGRESS" => "1" }
      env["HB_CLAUDE_AUTH"] = File.expand_path(profile.auth_path) if profile.harness == "claude" && profile.auth_path
      env["HB_CODEX_AUTH"] = File.expand_path(profile.auth_path) if profile.harness == "codex" && profile.auth_path
      env
    end

    # Runs the isolated gen command, capturing stdout/stderr to temp files rather
    # than pipes — robust for the multi-MB agent JSON streams that race Open3's
    # reader threads. Returns [out, err, Process::Status].
    def run_to_files(env, script, cwd, cmd)
      out_file = Tempfile.new("hb-gen-out")
      err_file = Tempfile.new("hb-gen-err")
      system(env, "bash", script, "gen", cwd, cmd, out: out_file.path, err: err_file.path)
      status = $CHILD_STATUS
      [File.read(out_file.path), File.read(err_file.path), status]
    ensure
      out_file&.close!
      err_file&.close!
    end

    # Dispatch the agent's machine-readable output to its harness parser.
    def parse_stream(harness, out)
      case harness
      when "claude" then parse_claude_result(out)
      when "codex" then parse_codex_stream(out)
      else parse_pi_stream(out)
      end
    end

    # Builds the in-container agent invocation. pi (open models) and claude are
    # wired; codex is not yet. Every command cd's into the mounted repo, reads the
    # plan from a /work file ("$(cat …)" — no host-shell re-expansion), runs
    # headless in JSON mode, and is bounded by `timeout` so a wedged agent can't
    # hang the pass.
    def agent_command(profile)
      case profile.harness
      when "pi" then pi_command(profile.model)
      when "claude" then claude_command(profile.model)
      when "codex" then codex_command(profile.model)
      else
        raise UnsupportedHarness, "gen_exec has no wired command for #{profile.id} (#{profile.harness})"
      end
    end

    # `--offline` disables only pi's auxiliary startup fetches (version/telemetry);
    # the model API call — the egress HB_ALLOW_EGRESS acknowledges — still goes out.
    def pi_command(model)
      "cd /work && timeout #{agent_timeout} pi -p --mode json --no-session --no-approve --offline " \
        "--model #{model} \"$(cat /work/#{PROMPT_FILE})\""
    end

    # claude-code headless: --dangerously-skip-permissions trusts the work tree
    # (no interactive prompt); --output-format json emits one result object with
    # usage + total_cost_usd. OAuth creds are mounted by isolation.sh (see gen_env).
    def claude_command(model)
      "cd /work && timeout #{agent_timeout} claude -p --model #{model} --dangerously-skip-permissions " \
        "--output-format json \"$(cat /work/#{PROMPT_FILE})\""
    end

    # codex exec headless: --json emits JSONL events (turn.completed carries usage);
    # xhigh reasoning per the slate; bypass codex's own approvals/sandbox since we
    # provide the isolation. OAuth creds are mounted by isolation.sh (see gen_env).
    # codex runs as root (its app-server needs uid 0), so it chowns the work tree
    # back to the host uid afterward — otherwise the host can't capture/clean it.
    def codex_command(model)
      "cd /work && timeout #{agent_timeout} codex exec --json -m #{model} " \
        "-c 'model_reasoning_effort=\"xhigh\"' --dangerously-bypass-approvals-and-sandbox " \
        "\"$(cat /work/#{PROMPT_FILE})\"; " \
        "ec=$?; chown -R #{Process.uid}:#{Process.gid} /work 2>/dev/null; exit $ec"
    end

    # A malformed HB_AGENT_TIMEOUT override falls back to the default rather than
    # crashing the pass.
    def agent_timeout
      t = Integer(ENV.fetch("HB_AGENT_TIMEOUT", ""), exception: false)
      t&.positive? ? t : DEFAULT_AGENT_TIMEOUT
    end

    # Identical framing for every candidate so the comparison stays fair: the
    # frozen plan is the task; the agent implements it to completion in the tree.
    def frame_prompt(plan)
      <<~PROMPT
        You are an autonomous coding agent working in a git repository. Implement
        the plan below by making all necessary changes directly in the working
        tree. Do not ask questions; work to completion.

        <plan>
        #{plan}
        </plan>
      PROMPT
    end

    # Planner framing for the e2e pipeline. The planner gets the SAME ideation
    # context a hive planning agent has — the idea, the brainstorm (the clarifying
    # Q&A that pinned down the requirements), any referenced screenshots, and the
    # full repo — and writes its OWN implementation plan to PLAN_OUTPUT_FILE. It is
    # "from idea" in that it is NOT handed the frozen plan; it must produce the plan
    # itself. It must NOT implement the task. `assets` are in-repo relative paths to
    # screenshots staged into the checkout so the idea's image references resolve.
    def frame_plan_prompt(idea, brainstorm, assets: [])
      <<~PROMPT
        You are a senior engineer planning a feature for THIS repository. You are
        given the original idea and the brainstorm (the clarifying Q&A that pinned
        down the requirements) — the same context a hive planning agent receives.
        #{asset_instructions(assets)}Explore the repository to ground the plan in the real code, then write a
        detailed, step-by-step implementation plan to the file `#{PLAN_OUTPUT_FILE}`
        in the repository root. Do NOT implement the task — produce ONLY the plan,
        complete enough that another engineer could execute it without further context.

        <idea>
        #{idea}
        </idea>

        <brainstorm>
        #{brainstorm}
        </brainstorm>
      PROMPT
    end

    # A prompt fragment pointing the planner at staged screenshots (empty when the
    # task ships none). Trailing newline so it slots cleanly before "Explore…".
    def asset_instructions(assets)
      return "" if assets.empty?

      "The idea references screenshot(s) checked out in this repository — OPEN AND " \
        "STUDY each one; they convey the desired UI/behavior and are essential to " \
        "scoping the work correctly:\n#{assets.map { |a| "  - #{a}" }.join("\n")}\n"
    end

    # Parses pi's `--mode json` stream. Token usage and provider cost accumulate
    # across every assistant turn (tool-calling runs make many model calls), so
    # we SUM the per-message usage rather than taking the last turn's. We also
    # collect any provider `errorMessage` (e.g. a 402/429) so the caller can run
    # limit-detection over the error channel rather than the agent's prose.
    # Returns { usage: { input:, output:, cached:, cost: }, model:, errors: [] }.
    def parse_pi_stream(stdout)
      input = output = cached = 0
      cost = 0.0
      model = nil
      seen = false
      errors = []

      stdout.to_s.each_line do |line|
        msg = parse_assistant_message(line)
        next unless msg

        seen = true
        model ||= msg["model"]
        errors << msg["errorMessage"] if msg["errorMessage"]
        usage = msg["usage"] || {}
        input  += usage["input"].to_i
        output += usage["output"].to_i
        cached += usage["cacheRead"].to_i
        cost   += message_cost(usage)
      end

      usage = seen ? { input: input, output: output, cached: cached, cost: cost.round(6) } : {}
      { usage: usage, model: model, errors: errors }
    end

    # pi reports cost as { "cost": { "total": <n> } }, but tolerate a scalar
    # ("cost": <n>) or a missing field so one off-shape line never aborts a pass.
    def message_cost(usage)
      c = usage["cost"]
      (c.is_a?(Hash) ? c["total"] : c).to_f
    end

    # An assistant `message_end` event carries the finalized per-call usage; we
    # key off message_end (not message_start) so each model call counts once.
    def parse_assistant_message(line)
      obj = JSON.parse(line)
      return nil unless obj["type"] == "message_end"

      msg = obj["message"]
      return nil unless msg.is_a?(Hash) && msg["role"] == "assistant"

      msg
    rescue JSON::ParserError
      nil
    end

    # claude -p --output-format json emits ONE result object: usage (input/output/
    # cache tokens) + total_cost_usd + is_error + modelUsage. Returned in the same
    # { usage:, model:, errors: } shape as parse_pi_stream so gen_exec is uniform.
    def parse_claude_result(out)
      obj = claude_result_object(out)
      return { usage: {}, model: nil, errors: [] } unless obj

      usage = claude_usage(obj)
      errors = obj["is_error"] ? [claude_error_text(obj)] : []
      # model is intentionally nil: claude-code's `modelUsage` mixes the requested
      # model with auxiliary ones (haiku for titles etc.), so the honest label is
      # the REQUESTED model — gen_exec fills that in from profile.model.
      { usage: usage, model: nil, errors: errors }
    end

    def claude_usage(obj)
      u = obj["usage"] || {}
      return {} if u.empty?

      { input: u["input_tokens"].to_i, output: u["output_tokens"].to_i,
        cached: u["cache_read_input_tokens"].to_i, cost: (obj["total_cost_usd"] || 0).to_f.round(6) }
    end

    # The whole output is normally one object (pretty or single-line); fall back to
    # a reverse line scan for stream-json or stray leading output.
    def claude_result_object(out)
      whole = try_json(out)
      return whole if claude_result?(whole)

      out.to_s.lines.reverse_each do |line|
        obj = try_json(line.strip)
        return obj if claude_result?(obj)
      end
      nil
    end

    def claude_result?(obj)
      obj.is_a?(Hash) && (obj.key?("usage") || obj["type"] == "result")
    end

    def claude_error_text(obj)
      (obj["result"] || obj["api_error_status"] || "claude error").to_s
    end

    # codex exec --json emits JSONL events; `turn.completed` carries per-turn usage
    # (input/output/cached/reasoning tokens). Sum across turns. codex reports no
    # dollar cost (subscription auth), so cost is left out. Same return shape as
    # the others. reasoning tokens are billed as output, so they're counted there.
    def parse_codex_stream(out)
      input = output = cached = 0
      seen = false
      errors = []

      out.to_s.each_line do |line|
        obj = try_json(line)
        next unless obj.is_a?(Hash)

        if obj["type"] == "turn.completed" && obj["usage"].is_a?(Hash)
          u = obj["usage"]
          seen = true
          input  += u["input_tokens"].to_i
          output += u["output_tokens"].to_i + u["reasoning_output_tokens"].to_i
          cached += u["cached_input_tokens"].to_i
        end
        errors << codex_error_text(obj) if codex_error?(obj)
      end

      usage = seen ? { input: input, output: output, cached: cached } : {}
      { usage: usage, model: nil, errors: errors }
    end

    def codex_error?(obj)
      obj["type"].to_s.include?("error") || obj.key?("error")
    end

    def codex_error_text(obj)
      (obj["message"] || obj.dig("error", "message") || obj["error"] || "codex error").to_s
    end

    def try_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end
  end
end
