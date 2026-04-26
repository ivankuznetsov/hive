require "fileutils"
require "digest"
require "open3"
require "hive/stages/base"
require "hive/worktree"
require "hive/git_ops"
require "hive/markers"
require "hive/reviewers"
require "hive/agent_profiles"
require "hive/stages/review/ci_fix"
require "hive/stages/review/triage"
require "hive/stages/review/browser_test"
require "hive/stages/review/fix_guardrail"

module Hive
  module Stages
    # 5-review stage runner. Integrates U4 (reviewer adapter),
    # U6 (triage), U7 (CI-fix), U8 (browser-test), and U13 (post-fix
    # guardrail) into the autonomous loop documented in the plan:
    #
    #   Phase 1: CI-fix (once on entry)
    #   Phase 2: sequential reviewers
    #   Phase 3: triage
    #   Branch:
    #     - any [x] → Phase 4 (fix) → loop to Phase 2 with pass++
    #     - escalations only → REVIEW_WAITING (terminal)
    #     - all clean → Phase 5
    #   Phase 5: browser-test → REVIEW_COMPLETE (passed | warned | skipped)
    #
    # Wall-clock budget (review.max_wall_clock_sec) is enforced at
    # every phase boundary. Pass-cap (review.max_passes) is enforced
    # before re-entering Phase 2 with pass++.
    #
    # Each `hive run` either lands a terminal marker (REVIEW_COMPLETE,
    # REVIEW_WAITING, REVIEW_CI_STALE, REVIEW_STALE, REVIEW_ERROR) or
    # exhausts the per-spawn budgets — there are no partial-run states
    # the user has to manually reconcile.
    module Review
      module_function

      # Files protected by SHA-256 around the fix agent (Phase 4). The
      # runner snapshots before+after; a mismatch yields REVIEW_ERROR
      # phase=fix reason=fix_tampered. Same pattern as ADR-013 for
      # 4-execute, narrowed to the orchestrator-owned files plus the
      # current pass's escalations doc (which only Triage may write).
      FIX_PROTECTED_FILES = %w[plan.md worktree.yml task.md].freeze

      def run!(task, cfg)
        # Track the current phase in a module-instance variable so the
        # top-level rescue at the end of this method can record it on
        # REVIEW_ERROR. The hive runner is single-task per process, so
        # cross-invocation contamination isn't a concern.
        @current_phase = :pre_flight

        # Pre-flight terminal markers
        marker = Hive::Markers.current(task.state_file)
        case marker.name
        when :review_complete
          warn "hive: already complete; mv this folder to 6-pr/ to continue"
          return { commit: nil, status: :review_complete }
        when :review_ci_stale
          warn "hive: REVIEW_CI_STALE — fix CI failures, edit reviews/ci-blocked.md, remove the marker, then re-run"
          return { commit: nil, status: :review_ci_stale }
        when :review_stale
          warn "hive: REVIEW_STALE — edit reviewer files / escalations.md, lower the highest-pass-N reviewer files, remove the marker, then re-run"
          return { commit: nil, status: :review_stale }
        when :review_error
          warn "hive: REVIEW_ERROR (#{marker.attrs.inspect}) — investigate, clear the marker, then re-run"
          return { commit: nil, status: :review_error }
        end

        # Worktree pointer must exist (carried over from 4-execute).
        unless File.exist?(task.worktree_yml_path)
          warn "hive: 5-review entered without a worktree.yml — this task did not pass through 4-execute. Move it back."
          exit 1
        end

        worktree_root = canonical_worktree_root(task, cfg)
        pointer = Hive::Worktree.read_pointer(task.folder)
        worktree_path = pointer["path"]
        Hive::Worktree.validate_pointer_path(worktree_path, worktree_root)
        unless File.directory?(worktree_path)
          warn "hive: worktree pointer present but worktree missing at #{worktree_path}; recover with `git -C <root> worktree prune`, fix worktree.yml, then re-run"
          exit 1
        end

        ops = Hive::GitOps.new(task.project_root)
        default_branch = ops.default_branch

        ctx = Hive::Reviewers::Context.new(
          worktree_path: worktree_path,
          task_folder: task.folder,
          default_branch: default_branch,
          pass: 0 # placeholder; per-pass calls override
        )

        started_at = Time.now
        max_wall_clock = cfg.dig("review", "max_wall_clock_sec") || 5400

        # --- Phase 1: CI fix ---
        # Resume rule: if marker is :review_waiting, the CI was already
        # green when we got there (otherwise we'd be at :review_ci_stale).
        # Skip CI on REVIEW_WAITING resume to honor the user's manual
        # edits without re-running everything.
        unless marker.name == :review_waiting
          @current_phase = :ci
          mark_working(task, phase: :ci, pass: 1)
          ci_result = Hive::Stages::Review::CiFix.run!(cfg: cfg, ctx: ctx)
          if wall_clock_exceeded?(started_at, max_wall_clock)
            return finalize_wall_clock_stale(task, started_at, pass: 1)
          end

          case ci_result.status
          when :stale
            write_ci_blocked(task, ci_result)
            Hive::Markers.set(task.state_file, :review_ci_stale, attempts: ci_result.attempts)
            return { commit: "ci_stale_attempts_#{ci_result.attempts}", status: :review_ci_stale }
          when :error
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :ci, reason: "ci_unrunnable")
            return { commit: "ci_error", status: :review_error }
          when :skipped, :green
            # proceed to Phase 2
          end
        end

        # --- Pass loop: Phase 2 → 3 → branch → 4 ---
        pass = next_pass_for(task, marker)
        max_passes = cfg.dig("review", "max_passes") || 4

        loop do
          if wall_clock_exceeded?(started_at, max_wall_clock)
            return finalize_wall_clock_stale(task, started_at, pass: pass)
          end

          if pass > max_passes
            Hive::Markers.set(task.state_file, :review_stale, pass: pass - 1)
            return { commit: "stale_max_passes", status: :review_stale }
          end

          ctx_pass = ctx.with(pass: pass)

          # If we resumed from REVIEW_WAITING, skip Phase 2/3 — user
          # already edited [x] marks; go directly to Phase 4.
          unless resuming_from_waiting?(marker, pass)
            @current_phase = :reviewers
            mark_working(task, phase: :reviewers, pass: pass)
            reviewers_result = run_reviewers(cfg, ctx_pass, task)
            if reviewers_result == :all_failed
              Hive::Markers.set(task.state_file, :review_error,
                                phase: :reviewers, reason: "all_failed", pass: pass)
              return { commit: "reviewers_all_failed_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end

            if wall_clock_exceeded?(started_at, max_wall_clock)
              return finalize_wall_clock_stale(task, started_at, pass: pass)
            end

            if triage_enabled?(cfg)
              @current_phase = :triage
              mark_working(task, phase: :triage, pass: pass)
              triage_result = Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx_pass)
              case triage_result.status
              when :tampered
                Hive::Markers.set(task.state_file, :review_error,
                                  phase: :triage, reason: "triage_tampered",
                                  files: triage_result.tampered_files.join(","), pass: pass)
                return { commit: "triage_tampered_pass_#{format('%02d', pass)}",
                         status: :review_error }
              when :error
                Hive::Markers.set(task.state_file, :review_error,
                                  phase: :triage, reason: "triage_failed", pass: pass)
                return { commit: "triage_error_pass_#{format('%02d', pass)}",
                         status: :review_error }
              end
            else
              write_manual_escalations(ctx_pass)
            end
          end

          # Branch on triage output. Read per-reviewer files for [x]
          # count (source of truth). escalations file existence + line
          # count tells us whether anything was escalated.
          accepted = collect_accepted_findings(ctx_pass)
          escalations_count = count_escalations(ctx_pass)

          if accepted.strip.empty? && escalations_count.zero?
            # Phase 2 produced zero findings → skip Phase 4, jump to Phase 5
            break
          end

          if accepted.strip.empty?
            # Escalations only — pause for user gate.
            Hive::Markers.set(task.state_file, :review_waiting,
                              escalations: escalations_count, pass: pass)
            return { commit: "review_waiting_pass_#{format('%02d', pass)}",
                     status: :review_waiting }
          end

          # --- Phase 4: fix ---
          @current_phase = :fix
          mark_working(task, phase: :fix, pass: pass)
          before_fix_sha = sha256_for(task, FIX_PROTECTED_FILES)
          before_fix_head = git_head(worktree_path)

          fix_result = spawn_fix_agent(task, cfg, ctx_pass, accepted: accepted)
          after_fix_sha = sha256_for(task, FIX_PROTECTED_FILES)
          after_fix_head = git_head(worktree_path)

          if (tampered = diff_hashes(before_fix_sha, after_fix_sha)).any?
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix, reason: "fix_tampered",
                              files: tampered.join(","), pass: pass)
            return { commit: "fix_tampered_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          if agent_failed?(fix_result)
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix, reason: "fix_failed", pass: pass)
            return { commit: "fix_error_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          if worktree_dirty?(worktree_path)
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix, reason: "fix_dirty_worktree", pass: pass)
            return { commit: "fix_dirty_worktree_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          # Post-fix diff guardrail (U13 stub today).
          guardrail = Hive::Stages::Review::FixGuardrail.run!(
            cfg: cfg, ctx: ctx_pass,
            base_sha: before_fix_head,
            head_sha: after_fix_head
          )
          if guardrail.status == :tripped
            write_fix_guardrail_findings(ctx_pass, guardrail.matches)
            Hive::Markers.set(task.state_file, :review_waiting,
                              reason: "fix_guardrail",
                              matches: guardrail.matches.size, pass: pass)
            return { commit: "review_waiting_fix_guardrail_pass_#{format('%02d', pass)}",
                     status: :review_waiting }
          end

          # On the next iteration, treat as fresh entry (not waiting-resume).
          marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
          pass += 1
        end

        # --- Phase 5: browser test ---
        @current_phase = :browser
        mark_working(task, phase: :browser, pass: pass)
        browser_result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg, ctx: ctx.with(pass: pass))

        case browser_result.status
        when :passed, :skipped, :warned
          Hive::Markers.set(task.state_file, :review_complete,
                            pass: pass, browser: browser_result.status)
          { commit: "review_complete_browser_#{browser_result.status}_pass_#{format('%02d', pass)}",
            status: :review_complete }
        else
          Hive::Markers.set(task.state_file, :review_error,
                            phase: :browser, reason: "browser_unexpected", pass: pass)
          { commit: "browser_error_pass_#{format('%02d', pass)}", status: :review_error }
        end
      rescue SystemExit
        # `exit 1` calls in pre-flight (worktree.yml missing, worktree
        # path missing) are intentional terminations — let them through
        # so the existing test contract is preserved.
        raise
      rescue StandardError => e
        # Any uncaught helper exception would otherwise leave a stale
        # REVIEW_WORKING marker on disk. Translate to REVIEW_ERROR with
        # the best-known phase so the user (and `hive run --json`) sees
        # the failure state, then re-raise so the runner / test suite
        # still surfaces the underlying bug.
        Hive::Markers.set(task.state_file, :review_error,
                          phase: @current_phase || :pre_flight,
                          reason: "runner_exception",
                          exception_class: e.class.name)
        raise
      end

      # --- helpers ---------------------------------------------------------

      def canonical_worktree_root(task, cfg)
        cfg["worktree_root"] || File.expand_path("~/Dev/#{File.basename(task.project_root)}.worktrees")
      end

      def mark_working(task, phase:, pass:)
        Hive::Markers.set(task.state_file, :review_working, phase: phase, pass: pass)
      end

      def triage_enabled?(cfg)
        cfg.dig("review", "triage", "enabled") != false
      end

      def wall_clock_exceeded?(started_at, max_seconds)
        Time.now - started_at >= max_seconds
      end

      def finalize_wall_clock_stale(task, started_at, pass:)
        elapsed = (Time.now - started_at).to_i
        Hive::Markers.set(task.state_file, :review_stale,
                          reason: "wall_clock", pass: pass, elapsed: elapsed)
        { commit: "stale_wall_clock_pass_#{format('%02d', pass)}",
          status: :review_stale }
      end

      # Pass to start at on a fresh hive run. Falls back to 1 when no
      # reviewer files exist yet.
      def next_pass_for(task, marker)
        max = max_review_pass(task.folder)
        case marker.name
        when :review_waiting
          # Prefer the marker-recorded pass over the disk-derived max.
          # Drift (e.g. user wrote a higher reviews/foo-NN.md than the
          # marker's pass) would otherwise cause Phase 2/3 to re-run
          # against a higher pass and overwrite the user's [x] marks.
          recorded = marker.attrs["pass"].to_i
          return recorded if recorded >= 1

          # Resume on the same pass — user toggled [x] in current pass's
          # files and wants a fix run on it.
          [ max, 1 ].max
        else
          max + 1
        end
      end

      def resuming_from_waiting?(marker, pass)
        marker.name == :review_waiting &&
          marker.attrs["pass"].to_i == pass
      end

      def max_review_pass(task_folder)
        glob = File.join(task_folder, "reviews", "*-*.md")
        max = 0
        Dir[glob].each do |path|
          name = File.basename(path)
          next if name.start_with?("escalations-")
          next if name.start_with?("ci-blocked")
          next if name.start_with?("browser-")
          next if name.start_with?("fix-guardrail-")

          if name =~ /-(\d{2})\.md\z/
            n = Regexp.last_match(1).to_i
            max = n if n > max
          end
        end
        max
      end

      # Run every configured reviewer sequentially. Returns :all_failed
      # if every reviewer's adapter returned :error; :ok when at least
      # one succeeded; :ok also when specs is empty (no reviewers
      # configured = nothing to triage; loop proceeds to Phase 5 via
      # the all-clean branch).
      def run_reviewers(cfg, ctx, task)
        specs = Array(cfg.dig("review", "reviewers"))
        return :ok if specs.empty?

        statuses = []
        specs.each do |spec|
          adapter = Hive::Reviewers.dispatch(spec, ctx)
          # Wrap adapter.run! so a single reviewer raising (spawn-time
          # SystemCallError, network timeout in a custom adapter, …)
          # doesn't abort the whole reviewers phase. Treat as :error,
          # write the stub finding (matches the result.error? path), and
          # continue with the next reviewer.
          result =
            begin
              adapter.run!
            rescue StandardError => e
              Hive::Reviewers::Result.new(
                name: spec["name"],
                output_path: adapter.output_path,
                status: :error,
                error_message: "#{e.class}: #{e.message}"
              )
            end
          statuses << result.status

          if result.error?
            # Stub finding file so triage has SOMETHING to read for
            # this reviewer at this pass; otherwise discover_reviewer_files
            # would silently skip it.
            FileUtils.mkdir_p(File.dirname(adapter.output_path))
            File.write(
              adapter.output_path,
              "## High\n\n- [ ] reviewer #{spec['name'].inspect} failed: #{result.error_message}\n"
            )
          end
        end

        statuses.all?(:error) ? :all_failed : :ok
      end

      # All [x] lines across every per-reviewer file for the current
      # pass, concatenated. Used by Phase 4's fix-agent prompt.
      def collect_accepted_findings(ctx)
        out = +""
        Dir[File.join(ctx.task_folder, "reviews", "*-#{format('%02d', ctx.pass)}.md")].sort.each do |path|
          name = File.basename(path)
          next if name.start_with?("escalations-")
          next if name.start_with?("ci-blocked")
          next if name.start_with?("browser-")
          next if name.start_with?("fix-guardrail-")

          File.readlines(path).each do |line|
            out << "[#{name}] #{line}" if line =~ /^\s*-\s+\[x\]\s+/
          end
        end
        out
      end

      def count_escalations(ctx)
        path = Hive::Stages::Review::Triage.escalations_path(ctx)
        return 0 unless File.exist?(path)

        File.readlines(path).count { |l| l =~ /^\s*-\s+\[\s*\]\s+/ }
      end

      def write_manual_escalations(ctx)
        path = Hive::Stages::Review::Triage.escalations_path(ctx)
        reviewer_files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
        FileUtils.mkdir_p(File.dirname(path))

        body = +"# Escalations for pass #{format('%02d', ctx.pass)}\n\n"
        body << "_Triage disabled; all unchecked reviewer findings require user review._\n\n"

        reviewer_files.each do |reviewer_file|
          findings = File.readlines(reviewer_file).select { |line| line =~ /^\s*-\s+\[\s*\]\s+/ }
          next if findings.empty?

          body << "## #{File.basename(reviewer_file)}\n\n"
          findings.each { |line| body << line }
          body << "\n"
        end

        File.write(path, body)
      end

      def spawn_fix_agent(task, cfg, ctx, accepted:)
        profile_name = cfg.dig("review", "fix", "agent") || "claude"
        profile = Hive::AgentProfiles.lookup(profile_name)
        template = cfg.dig("review", "fix", "prompt_template") || "fix_prompt.md.erb"

        prompt = Hive::Stages::Base.render(
          template,
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            worktree_path: ctx.worktree_path,
            task_folder: ctx.task_folder,
            pass: ctx.pass,
            accepted_findings: accepted,
            task_slug: task.slug,
            triage_bias: triage_bias_for(cfg),
            reviewer_sources: reviewer_sources_for(ctx),
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )

        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ ctx.task_folder ],
          cwd: ctx.worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "review_fix") || 100,
          timeout_sec: cfg.dig("timeout_sec", "review_fix") || 2700,
          log_label: "review-fix-pass#{format('%02d', ctx.pass)}",
          profile: profile,
          status_mode: :exit_code_only
        )
      end

      # The triage bias configured for this run, surfaced into commit
      # trailers so `hive metrics rollback-rate` can compare bias presets.
      # Defaults to "courageous" — same default as Triage.run! itself.
      def triage_bias_for(cfg)
        cfg.dig("review", "triage", "bias") || "courageous"
      end

      # Comma-separated reviewer file basenames (sans extension and pass
      # suffix) for the current pass. Surfaced as the `Hive-Reviewer-Sources`
      # trailer so the metric can show which reviewers' findings drove
      # which fix commits. Excludes orchestrator-owned files (escalations,
      # ci-blocked, browser-, fix-guardrail-).
      def reviewer_sources_for(ctx)
        sources = Dir[File.join(ctx.task_folder, "reviews", "*-#{format('%02d', ctx.pass)}.md")]
                  .map { |p| File.basename(p, ".md") }
                  .reject { |n| n.start_with?("escalations-", "ci-blocked", "browser-", "fix-guardrail-") }
                  .map { |n| n.sub(/-\d{2}\z/, "") }
                  .uniq
                  .sort

        sources.empty? ? "none" : sources.join(",")
      end

      def write_ci_blocked(task, ci_result)
        path = File.join(task.folder, "reviews", "ci-blocked.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~MD)
          # CI blocked after #{ci_result.attempts} attempts

          The 5-review CI-fix loop hit `review.ci.max_attempts` without a green CI.
          Reviewers do NOT run on red CI. Read the failure below, fix manually,
          remove the `<!-- REVIEW_CI_STALE ... -->` marker from `task.md`, then
          re-run `hive run` to retry.

          ## Last captured CI output

          ```
          #{ci_result.last_output}
          ```
        MD
      end

      def write_fix_guardrail_findings(ctx, matches)
        path = File.join(
          ctx.task_folder,
          "reviews",
          "fix-guardrail-#{format('%02d', ctx.pass)}.md"
        )
        FileUtils.mkdir_p(File.dirname(path))
        body = +"# Fix-guardrail findings for pass #{format('%02d', ctx.pass)}\n\n"
        matches.each do |m|
          body << "- [ ] #{m.pattern_name}: #{m.file}:#{m.line || '?'}: #{m.snippet}\n"
        end
        File.write(path, body)
      end

      def git_head(worktree_path)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", "HEAD")
        status.success? ? out.strip : nil
      end

      def worktree_dirty?(worktree_path)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, "status", "--porcelain")
        !status.success? || !out.empty?
      end

      def sha256_for(task, names)
        names.each_with_object({}) do |name, h|
          path = File.join(task.folder, name)
          h[name] = File.exist?(path) ? Digest::SHA256.hexdigest(File.read(path)) : nil
        end
      end

      def diff_hashes(before, after)
        before.keys.reject { |k| before[k] == after[k] }
      end

      def agent_failed?(result)
        return true if result.nil?

        %i[error timeout].include?(result[:status])
      end
    end
  end
end
