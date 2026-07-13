# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"
require "open3"
require "lib/hive_config"
require "lib/agent_limit"
require "lib/pricing"

module HiveBench
  # Drives REAL hive (plan -> execute) for one (task x candidate) in the
  # hive-bench-runner container, then captures the candidate diff + telemetry.
  # This REPLACES the reimplemented Pipeline: the scored diff is hive's ACTUAL
  # output (real /ce-plan + real execute), not a toy prompt's. Returns a cell
  # shaped like Run::Cell so RunAll/Score consume it unchanged. (Review is a later
  # phase; v2 ships plan+execute.)
  #
  # Container recipe (proven in the Stage A/B bring-up):
  #   - non-root runner (claude refuses --dangerously-skip-permissions as root)
  #   - HOME=/home/asterio on a world-writable tmpfs, with the claude creds /
  #     settings / plugins bind-mounted at that SAME absolute path so the plugin
  #     installPaths resolve and `/ce-plan` is available
  #   - the target clone at /work; hive baked into the image as a gem
  class HiveDriver
    class ArtifactProvenanceMismatch < StandardError; end

    Cell = Data.define(:task_id, :agent_id, :mode, :model_version, :status,
                       :diff_path, :telemetry, :reason)

    IMAGE = ENV.fetch("HB_RUNNER_IMAGE", "hive-bench-runner:latest")
    STAGES_SH = File.expand_path("hive_stages.sh", __dir__)
    RESUME_EXECUTE_SH = File.expand_path("hive_resume_execute.sh", __dir__)
    PI_TOOL_STREAM = File.expand_path("pi_tool_stream.ts", __dir__)
    CLAUDE_DIR = File.expand_path("~/.claude")
    HOME = "/home/asterio"
    GROK_AUTH_DIR = File.expand_path(
      ENV.fetch("HB_GROK_AUTH_DIR", "~/.local/state/hive-bench/grok-auth")
    )
    GROK_AUTH = File.join(GROK_AUTH_DIR, "auth.json")
    GROK_AUTH_CONTAINER_DIR = "#{HOME}/.grok-auth".freeze
    GENERATION_IDENTITY = "generation-identity.json"
    RESUMABLE_EXECUTE_FAILURE = %r{\Astream\ disconnected\ before\ completion:\ (?:
      failed\ to\ lookup\ address\ information:.*|
      error\ sending\ request\ for\ url\ \(https://chatgpt\.com/backend-api/codex/responses\)
    )\z}ix
    AUTH_FAILURE = /(?:\b401\b|unauthorized|authentication failed|login required|missing bearer)/i
    PLAN_TIMEOUT = Integer(ENV.fetch("HB_HIVE_TIMEOUT", "5400")) # per container run, sec

    def initialize(reuse_existing:, reuse_unverified:, clock: -> { Time.now.utc }, runner: nil)
      @clock = clock
      @runner = runner # injectable container runner for tests; default shells docker
      @reuse_existing = reuse_existing
      @reuse_unverified = reuse_unverified
    end

    # entry: corpus entry hash (manifest + entry_dir + checkout_source).
    # candidate: a Slate candidate (id, plan/execute/review agents, claude_model, …).
    def call(entry:, candidate:, out_dir:)
      FileUtils.mkdir_p(out_dir)
      slug = entry.fetch("task_id")
      base = entry.dig("source", "base_commit") or raise ArgumentError, "entry has no source.base_commit"
      source = entry["checkout_source"] or raise ArgumentError, "entry has no checkout_source"
      work = File.expand_path(File.join(out_dir, "target")) # absolute: docker -v needs it
      identity = generation_identity(entry, candidate, base)

      if @reuse_existing && (recovered = recover_cell(entry, candidate, work, base, identity))
        return recovered
      end

      resume_marker_id = @reuse_existing && resumable_execute_marker(entry, candidate, work, identity)
      unless resume_marker_id
        setup_repo(source, base, work)
        seed_task(entry, slug, work)
        File.write(File.join(work, ".hive-state", "config.yml"), HiveConfig.to_yaml(candidate))
        init_state_repo(work)
        persist_generation_identity(work, identity)
      end

      started = @clock.call
      stdout = run_container(slug, base, work, candidate, out_dir, resume_marker_id: resume_marker_id)
      wall = (@clock.call - started).round(2)

      build_cell(entry, candidate, work, stdout, wall)
    end

    private

    # A completed Hive run can outlive result assembly (for example, telemetry
    # parsing or every judge failed after generation). Reuse it only when Hive's
    # persisted transcript and captured patch classify as a generated cell.
    def recover_cell(entry, candidate, work, base, identity)
      transcript = File.join(work, ".hb", "stages.out")
      patch = File.join(work, "candidate.patch")
      return unless File.file?(transcript) && File.file?(patch)

      stdout = File.read(transcript)
      diff = File.read(patch)
      status, = classify(stdout, work, diff)
      return unless status == "generated"

      verified = generation_identity_matches?(work, identity)
      unless verified || (@reuse_unverified && legacy_identity_matches?(work, candidate, base))
        raise ArtifactProvenanceMismatch,
              "completed artifact identity does not match this task/candidate; " \
              "pass --no-reuse-existing-artifacts to replace it"
      end

      provenance = verified ? "verified" : "legacy-unverified"
      build_cell(entry, candidate, work, stdout, nil, recovered: provenance)
    end

    # Resume only a provenance-matched Hive task whose final Codex turn failed
    # because model transport disappeared. Auth/usage limits and ordinary
    # implementation failures deliberately remain ineligible.
    def resumable_execute_marker(entry, candidate, work, identity)
      return unless candidate.execute == "codex"
      return unless generation_identity_matches?(work, identity)

      slug = entry.fetch("task_id")
      task_md = File.join(work, ".hive-state", "stages", "4-execute", slug, "task.md")
      return unless File.file?(task_md)

      marker = File.read(task_md)[/<!-- ERROR\b[^>]*-->/]
      return unless marker&.match?(/\breason=implementer_failed\b/)

      marker_id = marker[/\bmarker_id=([^\s>]+)/, 1]
      return unless marker_id

      logs = Dir.glob(File.join(work, ".hive-state", "logs", slug, "execute-*.log"))
      latest = logs.max_by { |path| File.mtime(path) }
      return unless latest

      terminal = File.foreach(latest).filter_map { |line| stream_json(line) }
                                     .reverse_each.find { |event| event["type"].to_s.start_with?("turn.") }
      return unless terminal&.fetch("type", nil) == "turn.failed"

      message = terminal.dig("error", "message").to_s
      return if AgentLimit.limit_hit?(message) || message.match?(AUTH_FAILURE)

      marker_id if message.match?(RESUMABLE_EXECUTE_FAILURE)
    rescue SystemCallError
      nil
    end

    def generation_identity(entry, candidate, base)
      JSON.parse(JSON.generate(
                   "schema" => "hive-bench-generation-identity",
                   "schema_version" => 1,
                   "task_id" => entry.fetch("task_id"),
                   "base_commit" => base,
                   "candidate" => candidate.to_h
                 ))
    end

    def persist_generation_identity(work, identity)
      dir = File.join(work, ".hb")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, GENERATION_IDENTITY), "#{JSON.pretty_generate(identity)}\n")
    end

    def generation_identity_matches?(work, expected)
      path = File.join(work, ".hb", GENERATION_IDENTITY)
      File.file?(path) && JSON.parse(File.read(path)) == expected
    rescue JSON::ParserError
      false
    end

    # Pre-identity runs can be recovered only through the explicit legacy opt-in.
    # Base and Hive config are still checked, but external model pins were not
    # persisted by those runs, so the result is visibly marked unverified.
    def legacy_identity_matches?(work, candidate, base)
      config = File.join(work, ".hive-state", "config.yml")
      head, _err, status = Open3.capture3("git", "-C", work, "rev-parse", "HEAD")
      status.success? && head.strip == base && File.file?(config) && File.read(config) == HiveConfig.to_yaml(candidate)
    end

    # Clone the target, reset local main to the task's base_commit, drop origin so
    # the execute worktree branches off base_commit (not origin/main).
    def setup_repo(source, base, work)
      FileUtils.rm_rf(work)
      git("clone", "--quiet", "--no-local", source, work)
      git("-C", work, "checkout", "-q", "-B", "main", base)
      git("-C", work, "remote", "remove", "origin")
    end

    def seed_task(entry, slug, work)
      tdir = File.join(work, ".hive-state", "stages", "2-brainstorm", slug)
      FileUtils.mkdir_p(tdir)
      File.write(File.join(tdir, "idea.md"), read_spec(entry, "idea"))
      File.write(File.join(tdir, "brainstorm.md"), read_spec(entry, "brainstorm"))
      File.write(File.join(tdir, "meta.yml"), "---\nid: 1\nslug: #{slug}\n")
      stage_assets(entry, tdir)
    end

    # The .hive-state is its own git repo (hive version-controls task state there).
    def init_state_repo(work)
      state = File.join(work, ".hive-state")
      git("-C", state, "init", "-q", "-b", "main")
      git("-C", state, "config", "user.email", "bench@hive-bench")
      git("-C", state, "config", "user.name", "hive-bench")
      git("-C", state, "add", "-A")
      git("-C", state, "commit", "-q", "-m", "seed @ 2-brainstorm")
    end

    # Copy spec screenshots into the task folder so the idea's `assets/<f>` refs
    # resolve for the plan agent (the same visual context the human had).
    def stage_assets(entry, tdir)
      src = File.join(entry.fetch("entry_dir"), "spec", "assets")
      return unless File.directory?(src)

      FileUtils.cp_r(src, File.join(tdir, "assets"))
    end

    def run_container(slug, base, work, candidate, out_dir, resume_marker_id: nil)
      cmd = ["docker", "run", "--rm",
             "-e", "HOME=#{HOME}",
             *(resume_marker_id ? ["-e", "HB_RESUME_EXECUTE=1", "-e", "HB_RESUME_MARKER_ID=#{resume_marker_id}"] : []),
             # Full-cycle by default (plan->execute->open-pr->review, the real
             # hive pipeline); HB_REVIEW=0 falls back to plan+execute only.
             "-e", "HB_REVIEW=#{ENV.fetch("HB_REVIEW", "1")}",
             # Resource caps: comparability (wall-clock cells shouldn't vary with
             # host contention) as much as containment. Generous — hive runs a
             # full plan+execute agent session in here.
             "--cpus", ENV.fetch("HB_CPUS", "4"),
             "--memory", ENV.fetch("HB_MEMORY", "8g"),
             "--pids-limit", ENV.fetch("HB_PIDS", "4096"),
             *network_args,
             "--tmpfs", "#{HOME}:exec,mode=1777",
             # .claude must be WRITABLE (claude's Bash tool mkdir's session-env
             # there) — a plain bind-mount parent is root-owned/ro and kills Bash,
             # so the agent gives up mid-execute. tmpfs it; the config is bound ro within.
             "--tmpfs", "#{HOME}/.claude:exec,mode=1777",
             "-v", "#{STAGES_SH}:/hive_stages.sh:ro",
             "-v", "#{RESUME_EXECUTE_SH}:/hive_resume_execute.sh:ro",
             "-v", "#{work}:/work",
             *auth_mounts(candidate, out_dir),
             *env_args(candidate),
             IMAGE,
             # HB_EXIT lets classify() tell a timeout (rc=124) from a stage
             # failure; tee persists the markers so a driver crash after the
             # (expensive) container run can never lose the classification.
             "mkdir -p /work/.hb; { timeout #{PLAN_TIMEOUT} bash /hive_stages.sh #{slug} #{base}; " \
             "echo HB_EXIT rc=$?; } | tee /work/.hb/stages.out"]
      (@runner || method(:capture)).call(cmd)
    end

    # Generation needs model-API egress, so `--network none` is impossible here —
    # but the default bridge leaves the answer key (the public reference PR)
    # fetchable. HB_GEN_NETWORK names a docker network (e.g. one behind an egress
    # allowlist proxy) to attach instead; until that's standing, the post-run
    # answer-key scan (`answer_key_suspect?`) is the detection layer.
    def network_args
      net = ENV.fetch("HB_GEN_NETWORK", nil)
      net ? ["--network", net] : []
    end

    # Mount the auth each used agent needs. claude: creds+settings+plugins at the
    # matching absolute path (so /ce-plan resolves). codex: its OAuth, read-only.
    def auth_mounts(candidate, out_dir)
      mounts = []
      if uses?(candidate, "claude")
        # RULE: never hand docker a bind-mount source unless it already exists
        # with the right type — docker creates a missing source as a root-owned
        # DIRECTORY on the host, which permanently breaks claude login there
        # (a token-refresh rename can even open that window transiently).
        claude_credentials = File.join(CLAUDE_DIR, ".credentials.json")
        raise "claude credentials missing or not a file: #{claude_credentials}" unless File.file?(claude_credentials)

        claude_settings = File.join(CLAUDE_DIR, "settings.json")
        raise "claude settings missing or not a file: #{claude_settings}" unless File.file?(claude_settings)

        claude_plugins = File.join(CLAUDE_DIR, "plugins")
        raise "claude plugins missing or not a directory: #{claude_plugins}" unless File.directory?(claude_plugins)

        mounts += ["-v", "#{claude_credentials}:#{HOME}/.claude/.credentials.json:ro",
                   "-v", "#{claude_settings}:#{HOME}/.claude/settings.json:ro",
                   "-v", "#{claude_plugins}:#{HOME}/.claude/plugins:ro"]
        # Prod parity: hive's default plan skill for claude is /plan (the
        # wiki+ce-plan wrapper). It resolves from user commands OR a plugin;
        # mount the user commands dir when the host has one (this host's /plan
        # lives in plugins, already mounted — so conditional, not fail-closed).
        claude_commands = File.join(CLAUDE_DIR, "commands")
        mounts += ["-v", "#{claude_commands}:#{HOME}/.claude/commands:ro"] if File.directory?(claude_commands)
      end
      codex = File.expand_path("~/.codex/auth.json")
      if uses?(candidate, "codex") && File.file?(codex)
        # Same trap as claude's .claude: a ro bind-mount's parent dir is created
        # root-owned inside the HOME tmpfs, and codex dies at startup unable to
        # write beside it ("failed to initialize in-process app-server client:
        # Permission denied"). tmpfs the dir; bind the auth ro within it.
        mounts += ["--tmpfs", "#{HOME}/.codex:exec,mode=1777",
                   "-v", "#{codex}:#{HOME}/.codex/auth.json:ro"]
        # Codex registers plugins in config.toml (found 2026-07-09: the cache
        # mount alone leaves skills unregistered). The bench GENERATES a
        # minimal config per cell — plugin registration + /work trust, plus
        # the effort pin for xhigh candidates — never the operator's own
        # config.toml (it carries personal MCP servers and project trusts).
        cfg = File.expand_path(File.join(out_dir, "codex-config.toml"))
        File.write(cfg, codex_config(candidate))
        mounts += ["-v", "#{cfg}:#{HOME}/.codex/config.toml:ro"]
      end
      if uses?(candidate, "codex") && File.file?(codex)
        # Native CE skills (prod parity, found missing 2026-07-09: codex's own
        # review log said the skill "is not available in the listed skills").
        # Mounted at a neutral path; hive_stages.sh links it into the ~/.codex
        # tmpfs (a direct bind under the tmpfs would leave root-owned parents).
        codex_cache = File.expand_path("~/.codex/plugins/cache")
        raise "codex plugin cache missing or not a directory: #{codex_cache}" unless File.directory?(codex_cache)

        mounts += ["-v", "#{codex_cache}:/opt/hb/codex-plugins-cache:ro"]
      end
      if uses?(candidate, "pi")
        # Same for pi: the compound-engineering skill tree from pi's plugin
        # checkout, linked into ~/.pi/agent/skills by hive_stages.sh.
        pi_skills = File.expand_path("~/.pi/agent/git/github.com/EveryInc/compound-engineering-plugin/skills")
        raise "pi CE skills missing or not a directory: #{pi_skills}" unless File.directory?(pi_skills)

        mounts += ["-v", "#{pi_skills}:/opt/hb/pi-ce-skills:ro",
                   "-v", "#{PI_TOOL_STREAM}:/opt/hb/pi-tool-stream.ts:ro"]
      end
      if uses?(candidate, "grok")
        # Keep sessions/config/leader state ephemeral per cell. Only the
        # separately authenticated benchmark credential is shared, so Grok can
        # atomically rotate auth.json under one cross-container lock domain.
        mounts += ["--tmpfs", "#{HOME}/.grok:exec,mode=1777",
                   "-v", "#{prepare_grok_auth_dir}:#{GROK_AUTH_CONTAINER_DIR}:rw"]
      end
      mounts
    end

    def prepare_grok_auth_dir
      FileUtils.mkdir_p(GROK_AUTH_DIR, mode: 0o700)
      state = File.lstat(GROK_AUTH_DIR)
      unless state.directory? && !state.symlink? && state.uid == Process.uid
        raise "grok benchmark auth directory is not user-owned: #{GROK_AUTH_DIR}"
      end

      File.chmod(0o700, GROK_AUTH_DIR)
      validate_grok_auth!
      validate_grok_auth_lock!
      GROK_AUTH_DIR
    end

    def validate_grok_auth!
      File.open(GROK_AUTH, File::RDONLY | File::NOFOLLOW) do |auth|
        unless private_grok_file?(auth.stat) && valid_grok_auth_payload?(auth.read)
          raise "grok benchmark credentials must be a user-owned mode-0600 refreshable login: #{GROK_AUTH}"
        end
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      raise "grok benchmark credentials missing: #{GROK_AUTH} " \
            "(run `GROK_AUTH_PATH=#{GROK_AUTH} grok login`)"
    rescue Errno::ELOOP, Errno::EISDIR
      raise "grok benchmark credentials are not a regular file: #{GROK_AUTH}"
    rescue SystemCallError => e
      raise "grok benchmark credentials cannot be read securely: #{GROK_AUTH} (#{e.class})"
    end

    def valid_grok_auth_payload?(payload)
      data = JSON.parse(payload)
      data.is_a?(Hash) && data.values.any? do |entry|
        entry.is_a?(Hash) && !entry["key"].to_s.empty? && !entry["refresh_token"].to_s.empty?
      end
    rescue JSON::ParserError
      false
    end

    def validate_grok_auth_lock!
      lock_path = "#{GROK_AUTH}.lock"
      File.open(lock_path, File::RDONLY | File::NOFOLLOW) do |lock|
        raise "grok auth lock is not a safe regular file: #{lock_path}" unless safe_grok_lock_file?(lock.stat)
      end
    rescue Errno::ENOENT
      nil # Grok creates the lock on first refresh.
    rescue Errno::ELOOP, Errno::EISDIR
      raise "grok auth lock is not a regular file: #{lock_path}"
    rescue SystemCallError => e
      raise "grok auth lock cannot be read securely: #{lock_path} (#{e.class})"
    end

    def private_grok_file?(state)
      state.file? && state.uid == Process.uid && state.nlink == 1 && (state.mode & 0o777) == 0o600
    end

    def safe_grok_lock_file?(state)
      state.file? && state.uid == Process.uid && state.nlink == 1 && state.mode.nobits?(0o022)
    end

    # OPENROUTER_API_KEY is forwarded (never echoed) when a pi/open-model stage
    # runs, along with the per-stage pi model patterns the in-container pi shim
    # injects as `--model` (hive has no pi model config of its own). Grok's
    # model/effort pins ride the same shim mechanism (hive's grok profile
    # passes no model flags either).
    def env_args(candidate)
      args = []
      if uses?(candidate, "pi")
        args += ENV["OPENROUTER_API_KEY"] ? ["-e", "OPENROUTER_API_KEY"] : []
        (candidate.pi_models || {}).each do |stage, pattern|
          args += ["-e", "HB_PI_MODEL_#{stage.upcase}=#{pattern}"]
        end
      end
      if uses?(candidate, "grok")
        args += ["-e", "GROK_AUTH_PATH=#{GROK_AUTH_CONTAINER_DIR}/auth.json"]
        args += ["-e", "HB_GROK_MODEL=#{candidate.grok_model}"] if candidate.grok_model
        args += ["-e", "HB_GROK_EFFORT=#{candidate.grok_effort}"] if candidate.grok_effort
      end
      args
    end

    def uses?(candidate, agent)
      [candidate.plan, candidate.execute, candidate.review].include?(agent)
    end

    # Minimal per-cell codex config: CE plugin registration (the cache is
    # mounted + linked separately) + trust for /work, + the effort pin for
    # xhigh candidates. Deliberately NOT the operator's config.toml — that
    # carries personal MCP servers and host project trusts.
    def codex_config(candidate)
      # TOML: top-level keys must precede any [table] section, so the model
      # and effort pins go first.
      pins = +""
      pins << %(model = "#{candidate.codex_model}"\n) if candidate.codex_model
      pins << %(model_reasoning_effort = "#{candidate.codex_effort}"\n) if candidate.codex_effort
      pins << "\n" unless pins.empty?
      pins + <<~TOML
        [marketplaces.compound-engineering-plugin]
        source_type = "git"
        source = "https://github.com/EveryInc/compound-engineering-plugin.git"

        [plugins."compound-engineering@compound-engineering-plugin"]
        enabled = true

        [projects."/work"]
        trust_level = "trusted"
      TOML
    end

    # ---- result assembly ----

    def build_cell(entry, candidate, work, stdout, wall, recovered: nil)
      diff_path = File.join(work, "candidate.patch")
      diff = File.file?(diff_path) ? File.read(diff_path) : ""
      tel = telemetry(work).merge("wall_clock_sec" => wall)
      if recovered
        tel["recovered_artifact"] = true
        tel["artifact_provenance"] = recovered
      end
      price_telemetry(tel, candidate)
      # The plan ended WAITING (open questions) and the bench force-completed it —
      # a covariate of the known scope-fork variance; surfaced so it's analyzable.
      tel["plan_forced_complete"] = true if stdout&.match?(/^HB_NOTE plan_forced_complete$/)
      tel["execute_resumed"] = true if stdout&.match?(/^HB_NOTE execute_resumed$/)
      review_telemetry(tel, work, stdout)
      if (hit = answer_key_suspect(entry, work, stdout))
        # The agent appears to have touched the held-out reference PR — the score
        # would measure retrieval, not skill. Flag loudly; a curator adjudicates.
        tel["answer_key_access_suspect"] = hit
        warn "hive-bench: ANSWER-KEY ACCESS SUSPECT — #{entry["task_id"]}: #{hit}"
      end
      status, reason = classify(stdout, work, diff)
      cell(entry, candidate, status, status == "generated" ? diff_path : nil, tel, reason)
    end

    # Review-cycle telemetry. Review failing must NOT lose a generated cell —
    # the final diff falls back to the execute diff (hive_stages.sh copies it),
    # and the outcome is recorded so a "generated" cell whose review died is
    # never mistaken for a reviewed one. review_changed records whether review
    # actually altered the diff (the review-lift signal).
    def review_telemetry(tel, work, stdout)
      %w[open-pr review].each do |st|
        m = stdout.to_s[/^HB_STAGE #{st} rc=(\d+)$/, 1] or next
        tel["#{st.tr("-", "_")}_ok"] = m == "0"
      end
      if (status = stdout.to_s[/^HB_NOTE review_status=(\w+)$/, 1])
        tel["review_status"] = status
      end
      exec_patch = File.join(work, "candidate-execute.patch")
      final_patch = File.join(work, "candidate.patch")
      return unless File.file?(exec_patch) && File.file?(final_patch) && tel.key?("review_ok")

      tel["review_changed_diff"] = File.read(exec_patch) != File.read(final_patch)
    end

    # run_status from the stage markers + the captured diff. limit_hit (a provider
    # wall) parks the cell; an empty/failed plan or execute is surfaced honestly.
    def classify(stdout, work, diff)
      err = File.file?(f = File.join(work, ".hb", "stage.err")) ? File.read(f) : ""
      limit_hit = AgentLimit.limit_hit?("#{stdout}\n#{err}")
      # timeout(1) kills the whole stage script — a slow candidate, not one that
      # cannot plan. HB_EXIT comes from the run_container wrapper; any other
      # nonzero means the harness itself did not produce a trustworthy artifact.
      exit_rc = stdout.to_s[/^HB_EXIT rc=(\d+)$/, 1]&.to_i
      return ["timed_out", "hive run exceeded HB_HIVE_TIMEOUT (#{PLAN_TIMEOUT}s)"] if exit_rc == 124
      # Review is optional for generation integrity: hive_stages.sh atomically
      # restores candidate-execute.patch when review fails. A review-only limit
      # therefore defers review lift/Fable judging, not the already trustworthy
      # candidate generation. Limits before plan/develop completion still park.
      if limit_hit && (!stage_ok?(stdout, "plan") || !stage_ok?(stdout, "develop"))
        return ["limit_hit", "provider limit during a hive stage"]
      end
      return ["execute_failed", "hive stage runner exited #{exit_rc} before trustworthy capture"] if exit_rc && !exit_rc.zero?
      return ["plan_failed", "hive plan produced no plan.md"] unless stage_ok?(stdout, "plan")
      return ["execute_failed", "hive develop did not run"] unless stage_ok?(stdout, "develop")
      return ["empty_diff", "execute produced no diff"] if diff.strip.empty?

      ["generated", nil]
    end

    # Detects the one leakage that invalidates a cell outright: the candidate
    # reaching the held-out reference PR. Narrow on purpose (repo-qualified pull
    # URL or a `gh pr` invocation of that number) — the repo URL alone appears
    # legitimately in gemspecs/READMEs. Scans the agent stream logs + stdout.
    # Returns the matched evidence string, or nil.
    def answer_key_suspect(entry, work, stdout)
      repo = entry.dig("source", "repo")
      pr = entry.dig("source", "reference_pr")
      return nil unless repo && pr

      pattern = %r{#{Regexp.escape(repo)}/pulls?/#{pr}\b|\bgh\s+pr\s+(?:view|diff|checkout)\s+#{pr}\b}
      # Logs + captured stage stdout/stderr — a fetch attempt often surfaces only
      # in stderr (curl/gh error output lands in .hb/stage.err). .hb also holds
      # directories (bin/, origin.git/) — files only.
      haystacks = (Dir.glob(File.join(work, ".hive-state", "logs", "**", "*.log")) +
                   Dir.glob(File.join(work, ".hb", "*"))).select { |f| File.file?(f) }
      haystacks.each do |f|
        File.foreach(f) { |line| return line.strip[0, 200] if line.match?(pattern) }
      end
      (m = stdout.to_s[pattern]) ? m : nil
    end

    def stage_ok?(stdout, name)
      stdout =~ /^HB_STAGE #{name} rc=0$/
    end

    # Canonical cost is API-EQUIVALENT: tokens × the versioned usual-tier price
    # table (comparable across agents). The CLI's self-reported figure — fast-tier
    # for claude, often absent for codex/pi — is kept as cost_usd_reported. Mixed-
    # family candidates get no estimate (needs per-stage attribution): reported
    # stands alone and the leaderboard sees the gap instead of a wrong number.
    def price_telemetry(tel, candidate)
      reported = tel.delete("cost_usd")
      tel["cost_usd_reported"] = reported if reported
      # No token telemetry at all -> no estimate. An absent cost means "unknown";
      # writing a computed $0.00 would make a telemetry gap look like a free run.
      return tel unless tel.values_at("input_tokens", "output_tokens", "cached_tokens",
                                      "cache_creation_tokens").any?

      est = Pricing.estimate_usd(model_strings: [candidate.id, candidate.model_version],
                                 input: tel["input_tokens"], output: tel["output_tokens"],
                                 cached: tel["cached_tokens"],
                                 cache_creation: tel["cache_creation_tokens"])
      tel["cost_usd"] = est if est
      tel
    end

    # Sum token usage + cost across every stage's persisted agent stream log
    # (.hive-state/logs/<slug>/<stage>-*.log, lines prefixed `[stream] <ts> `).
    def telemetry(work)
      logs = Dir.glob(File.join(work, ".hive-state", "logs", "**", "*.log"))
      input = output = cached = cache_creation = 0
      cost = 0.0
      logs.each do |log|
        File.foreach(log) do |line|
          obj = stream_json(line) or next
          message = obj["message"]
          u = (message["usage"] if message.is_a?(Hash)) || obj["usage"]
          if u.is_a?(Hash)
            # Two stream schemas: claude's snake_case *_tokens and pi's camelCase
            # input/output/cacheRead/cacheWrite — without the aliases, open-model
            # cells recorded zero tokens and no cost.
            input += (u["input_tokens"] || u["input"]).to_i
            output += (u["output_tokens"] || u["output"]).to_i
            cached += (u["cache_read_input_tokens"] || u["cacheRead"]).to_i
            # Cache WRITES are billed too (claude: ~1.25x input rate) — dropping
            # them systematically understated the API-equivalent cost.
            cache_creation += (u["cache_creation_input_tokens"] || u["cacheWrite"]).to_i
          end
          cost += obj["total_cost_usd"].to_f if obj["type"] == "result"
        end
      end
      { "input_tokens" => input, "output_tokens" => output, "cached_tokens" => cached,
        "cache_creation_tokens" => cache_creation,
        "cost_usd" => cost.round(6) }.reject { |_, v| v.zero? }
    end

    # Extract the JSON object from a `[stream] <ts> {json}` log line (or a bare
    # json line); nil for narration lines.
    def stream_json(line)
      brace = line.index("{")
      return nil unless brace

      JSON.parse(line[brace..])
    rescue JSON::ParserError
      nil
    end

    def cell(entry, candidate, status, diff_path, telemetry, reason)
      Cell.new(task_id: entry.fetch("task_id"), agent_id: candidate.id, mode: "hive",
               model_version: candidate.model_version, status: status,
               diff_path: diff_path, telemetry: telemetry, reason: reason)
    end

    def read_spec(entry, key)
      rel = entry.dig("spec", key) or return ""
      path = File.join(entry.fetch("entry_dir"), rel)
      File.file?(path) ? File.read(path) : ""
    end

    def git(*args)
      _o, e, s = Open3.capture3("git", *args)
      raise "git #{args.first(3).join(" ")} failed: #{e.strip}" unless s.success?
    end

    def capture(cmd)
      out, _e, _s = Open3.capture3(*cmd)
      out
    end
  end
end
