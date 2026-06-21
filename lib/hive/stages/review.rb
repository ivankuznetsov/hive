require "digest"
require "fileutils"
require "open3"
require "time"
require "yaml"
require "hive/events"
require "hive/config"
require "hive/protected_files"
require "hive/claude_launcher"
require "hive/stages/base"
require "hive/stages/auto_commit"
require "hive/stages/clean_exit"
require "hive/worktree"
require "hive/git_ops"
require "hive/markers"
require "hive/agent_limit"
require "hive/reviewers"
require "hive/agent_profiles"
require "hive/stages/review/context"
require "hive/stages/review/orchestrator_owned"
require "hive/stages/review/ci_fix"
require "hive/stages/review/triage"
require "hive/stages/review/browser_test"
require "hive/stages/review/fix_guardrail"
require "hive/stages/review/github_publisher"
require "hive/workflows"

module Hive
  module Stages
    # 6-review stage runner. Integrates U4 (reviewer adapter),
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
      FIX_PROTECTED_FILES = Hive::ProtectedFiles::ORCHESTRATOR_OWNED

      # Filenames in `reviews/` that the orchestrator (not a reviewer)
      # writes are listed in `Hive::Stages::Review::ORCHESTRATOR_OWNED_PREFIXES`
      # (loaded from `orchestrator_owned.rb` so this list and Triage's
      # consumer can never drift). Triage's `discover_reviewer_files`
      # and the runner's max_review_pass / collect_accepted_findings /
      # reviewer_sources_for all need to skip these — otherwise a
      # `fix-guardrail-NN.md` user tick `[x]` would re-flow into the
      # next pass's fix prompt and over-amplify guardrail findings.
      ESCALATION_Q_RE = /^\s*###\s+Q(\d+)\.\s*(.*?)\s*$/.freeze
      ESCALATION_A_RE = /^\s*###\s+A(\d+)\.\s*$/.freeze

      # Per-pass sentinel: `reviews/fix-success-NN.md` is written after
      # a pass's Phase 4 fix succeeds (or Phase 2 produced zero findings
      # and the runner short-circuited to Phase 5). Its presence — or
      # the presence of any reviewer file for pass N+1 — proves pass N
      # completed cleanly. Absence + `escalations-NN.md` exists =>
      # the fix didn't complete, and `next_pass_for` retries pass N at
      # Phase 4 with the operator's existing `[x]` marks instead of
      # advancing past them.
      FIX_SUCCESS_FILENAME = "fix-success".freeze
      AcceptedFindings = Data.define(:text, :count)
      # Auto-commit scope constants now live on Hive::Stages::AutoCommit
      # (shared with CleanExit). Aliased here as compatibility constants —
      # external readers that referenced them via Review::CONSTANT continue
      # to work, and the in-file consumers (auto_commit_*) delegate to
      # AutoCommit module-functions instead of reaching for these.
      AUTO_COMMIT_SCOPE_GLOB_FLAGS = Hive::Stages::AutoCommit::AUTO_COMMIT_SCOPE_GLOB_FLAGS
      AutoCommitScopeViolation = Hive::Stages::AutoCommit::AutoCommitScopeViolation
      AUTO_COMMIT_SCOPE_FILENAME = "auto-commit-scope".freeze
      AUTO_COMMIT_OP_TIMEOUT_SEC = Hive::Stages::AutoCommit::AUTO_COMMIT_OP_TIMEOUT_SEC
      AUTO_COMMIT_SIGNING_ERROR_PATTERNS = Hive::Stages::AutoCommit::AUTO_COMMIT_SIGNING_ERROR_PATTERNS

      # Cap (characters) for the single-line `message=` attribute that
      # `mark_review_phase_failure` stamps onto a terminal review_error so the
      # real cause is surfaced without bloating task.md with a full agent
      # transcript. Longer messages are truncated with an ellipsis.
      REVIEW_PHASE_ERROR_SUMMARY_MAX = 300

      # `reviewer_file?` is defined in `review/orchestrator_owned.rb` so
      # this module and `Review::Triage` share one definition. Re-export
      # here as a class method so existing callers keep working.

      def fix_success_path(task_folder, pass)
        File.join(task_folder, fix_success_relative_path(pass))
      end

      def run!(task, cfg)
        # Track the current phase in a module-instance variable so the
        # top-level rescue at the end of this method can record it on
        # REVIEW_ERROR. The hive runner is single-task per process, so
        # cross-invocation contamination isn't a concern.
        @current_phase = :pre_flight
        # Phase-level agent_start/agent_end pair tracking. Each
        # mark_working call closes the previously-open phase event
        # (if any) and emits a new one. The ensure block at the bottom
        # of run! closes whatever phase is still open when the runner
        # exits (return, raise, or system_exit), so events.jsonl
        # readers always see balanced brackets.
        @open_phase_event = nil

        # Pre-flight terminal markers
        marker = Hive::Markers.current(task.state_file)
        case marker.name
        when :review_complete
          next_dir = Hive::Workflows.next_dir_after("6-review") # coding-scoped: coding review clears into artifacts
          warn "hive: already complete; mv this folder to #{next_dir}/ to continue"
          return { commit: nil, status: :review_complete }
        when :review_ci_stale
          warn "hive: REVIEW_CI_STALE — fix CI failures, edit reviews/ci-blocked.md, then run " \
               "`hive markers clear #{task.folder} --name REVIEW_CI_STALE` and re-run `hive run`"
          return { commit: nil, status: :review_ci_stale }
        when :review_stale
          warn "hive: REVIEW_STALE — if the highest pass has reviewer files but no escalations-NN.md, clear " \
               "the marker and re-run to retry it; otherwise edit/rename highest-pass review files, then run " \
               "`hive markers clear #{task.folder} --name REVIEW_STALE` and re-run `hive run`"
          return { commit: nil, status: :review_stale }
        when :review_error
          warn "hive: REVIEW_ERROR (#{marker.attrs.inspect}) — investigate, then run " \
               "`hive markers clear #{task.folder} --name REVIEW_ERROR` and re-run `hive run`"
          return { commit: nil, status: :review_error }
        end

        # Worktree pointer must exist (carried over from 4-execute).
        unless File.exist?(task.worktree_yml_path)
          warn "hive: 6-review entered without a worktree.yml — this task did not pass through 4-execute. Move it back."
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

        ops = Hive::GitOps.new(worktree_path)
        default_branch = reviewer_compare_ref(cfg, ops)

        ctx = Hive::Stages::Review::Context.new(
          worktree_path: worktree_path,
          task_folder: task.folder,
          default_branch: default_branch,
          pass: 0 # placeholder; per-pass calls override
        )

        started_at = Time.now
        max_wall_clock = cfg.dig("review", "max_wall_clock_sec") || 14_400

        # --- Phase 1: CI fix ---
        # Resume rule: if marker is :review_waiting, the CI was already
        # green when we got there (otherwise we'd be at :review_ci_stale).
        # Skip CI on REVIEW_WAITING resume to honor the user's manual
        # edits without re-running everything.
        unless marker.name == :review_waiting
          @current_phase = :ci
          mark_working(task, phase: :ci, pass: 1)
          ci_result = Hive::Stages::Review::CiFix.run!(
            cfg: cfg, ctx: ctx,
            started_at: started_at, max_wall_clock_sec: max_wall_clock
          )
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
        pass = next_pass_for(task, marker, cfg)
        max_passes = cfg.dig("review", "max_passes") || 4

        # When the runner is re-entering a pass whose Phase 4 fix did
        # not finish (REVIEW_ERROR phase=fix, or interrupted
        # REVIEW_WORKING phase=fix), pass_completion_status returns
        # :fix_incomplete and next_pass_for returns the same pass.
        # Skip Phase 2/3 on the first iteration (just like a
        # REVIEW_WAITING resume) so the operator's existing [x] marks
        # are preserved and the retry runs Phase 4 directly. Only
        # applies to the FIRST loop iteration; subsequent passes are
        # fresh and clear fix_retry_pass at the loop tail.
        fix_retry_pass = pass_completion_status(task.folder, pass) == :fix_incomplete ? pass : nil

        loop do
          if wall_clock_exceeded?(started_at, max_wall_clock)
            return finalize_wall_clock_stale(task, started_at, pass: pass)
          end

          if pass > max_passes
            Hive::Markers.set(task.state_file, :review_stale, pass: pass - 1)
            return { commit: "stale_max_passes", status: :review_stale }
          end

          ctx_pass = ctx.with(pass: pass)

          # U5 — fix-guardrail approval-on-resume. When the user has
          # ticked [x] on every line of reviews/fix-guardrail-NN.md
          # AND the resume marker is REVIEW_WAITING reason=fix_guardrail
          # for THIS pass, treat the prior Phase 4's commits as
          # user-approved: skip Phase 2/3 reviewers, do not re-spawn the
          # fix agent, and advance. The approval is single-shot per
          # pass: a future pass that re-trips the guardrail writes a
          # fresh fix-guardrail-(NN+1).md with [ ] lines; pass-N
          # approval does not transfer.
          #
          # MUST come BEFORE the resume_no_findings empty-guard so
          # approval doesn't require live reviewer files to land.
          #
          # Two safety checks before advancing:
          # worktree_dirty? catches manual edits between trip and
          # approval; the max_passes-boundary check breaks to Phase 5
          # instead of writing REVIEW_STALE on an approved pass. The
          # pass-match is handled by the enclosing `resuming_from_waiting?`
          # entry guard, so it's a precondition for entering this branch
          # rather than an additional check.
          if resuming_from_waiting?(marker, pass) &&
             marker.attrs["reason"] == "fix_guardrail"
            # Missing or malformed `matches` on a fix_guardrail marker
            # disables the truncation
            # defense. Treat that as a malformed marker rather than
            # silently degrading to count-blind approval. The marker
            # is hand-edited rarely, but when it is (e.g. an operator
            # debugging the stage), we want a hard error not a quiet
            # bypass.
            raw_matches = marker.attrs["matches"].to_s
            unless raw_matches.match?(/\A[1-9]\d*\z/)
              Hive::Markers.set(task.state_file, :review_error,
                                phase: :resume, reason: "malformed_marker_matches",
                                pass: pass)
              return { commit: "malformed_marker_matches_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end
            expected_matches = raw_matches.to_i

            # Verify the worktree HEAD is still the commit the guardrail
            # flagged. A user who amended/rebased/squashed between trip
            # and approval would otherwise have their `[x]` ticks honoured
            # against a diff the guardrail never scanned.
            #
            # Backward-compat: legacy markers written before the
            # head-binding feature carry no `head=` attr. Treating that
            # absence as "mismatch" would auto-error every in-flight
            # REVIEW_WAITING reason=fix_guardrail task on first resume
            # after upgrade. When the marker pre-dates the head-binding
            # feature, skip the HEAD check with a stderr notice; the
            # count + checkbox + worktree-clean gates still apply.
            guarded_head = marker.attrs["head"].to_s
            current_head = git_head(worktree_path).to_s
            if guarded_head.empty?
              warn "[hive.review] resume on legacy fix_guardrail marker without head= " \
                   "(task #{File.basename(task.folder)} pass #{pass}); HEAD-binding " \
                   "approval check skipped. Newer markers record head= and enforce " \
                   "this check."
            elsif current_head != guarded_head
              Hive::Markers.set(task.state_file, :review_error,
                                phase: :resume, reason: "approval_head_mismatch",
                                guarded_head: guarded_head, current_head: current_head,
                                pass: pass)
              return { commit: "approval_head_mismatch_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end

            if fix_guardrail_approved?(ctx_pass, expected_matches: expected_matches)
              if worktree_dirty?(worktree_path)
                Hive::Markers.set(task.state_file, :review_error,
                                  phase: :resume, reason: "approval_dirty_worktree", pass: pass)
                return { commit: "approval_dirty_worktree_pass_#{format('%02d', pass)}",
                         status: :review_error }
              end

              write_fix_success(ctx_pass)
              marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
              fix_retry_pass = nil
              # If we approved the very last pass-cap-N pass, advancing
              # to pass N+1 would immediately hit the `pass > max_passes`
              # guard above and write REVIEW_STALE — masking the
              # approval. Break to Phase 5 (browser test) instead so
              # the approved commits make it through to the terminal
              # state.
              break if pass >= max_passes

              pass += 1
              next
            else
              # Partial-approval defense. When the
              # user has ticked SOME `[x]` in fix-guardrail-NN.md but
              # not all, the prior PR-A behaviour was to fall through
              # to the generic REVIEW_WAITING resume path and re-spawn
              # the fix agent against the previous-pass reviewer `[x]`
              # marks. That violates the user's "I only approved some"
              # mental model and can launder a risky diff past the
              # guardrail when the fix agent's retry produces a clean
              # diff. Instead, hold the pause: leave the marker
              # untouched, return :review_waiting. Recovery options:
              # (a) tick the rest of the boxes, (b) `hive markers
              # clear FOLDER --name REVIEW_WAITING` and re-run, or
              # (c) revert the offending commits in the worktree.
              return { commit: "review_waiting_fix_guardrail_pending_pass_#{format('%02d', pass)}",
                       status: :review_waiting }
            end
          end

          # Two paths skip Phase 2/3 and jump to Phase 4 on existing
          # reviewer artefacts: (a) REVIEW_WAITING resume (user edited
          # [x] marks), (b) fix-retry on an interrupted pass. Both
          # require reviewer files for `pass` to exist; if the user
          # deleted them between runs, surface as REVIEW_ERROR
          # resume_no_findings instead of looping with an empty fix
          # prompt.
          skip_review_and_triage = resuming_from_waiting?(marker, pass) || pass == fix_retry_pass
          if skip_review_and_triage &&
             Hive::Stages::Review::Triage.discover_reviewer_files(ctx_pass).empty?
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :resume, reason: "resume_no_findings",
                              pass: pass)
            return { commit: "resume_no_findings_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          # If we resumed from REVIEW_WAITING or are retrying an
          # incomplete-fix pass, skip Phase 2/3 — reviewer files +
          # [x] marks already exist; go directly to Phase 4.
          unless skip_review_and_triage
            @current_phase = :reviewers
            mark_working(task, phase: :reviewers, pass: pass)
            reviewers_result = run_reviewers(
              cfg, ctx_pass, task,
              started_at: started_at, max_wall_clock_sec: max_wall_clock
            )
            if reviewers_result == :wall_clock_exceeded
              return finalize_wall_clock_stale(task, started_at, pass: pass)
            end
            if reviewers_result == :all_failed || reviewers_result == :all_failed_limit
              limit = reviewers_result == :all_failed_limit
              reason = limit ? "limits_reached" : "all_failed"
              attrs = { phase: :reviewers, reason: reason, pass: pass }
              if limit
                attrs[:message] = "all reviewers hit a usage/credit limit"
                # Stamp the cooldown so the daemon healer can self-heal once
                # the usage window has plausibly reset (see AgentLimit). Only
                # the limit marker gets a retry_after — `all_failed` stays manual.
                attrs[:retry_after] = Hive::AgentLimit.retry_after
              end
              Hive::Markers.set(task.state_file, :review_error, attrs)
              return { commit: "reviewers_#{reason}_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end

            if wall_clock_exceeded?(started_at, max_wall_clock)
              return finalize_wall_clock_stale(task, started_at, pass: pass)
            end

            if triage_enabled?(cfg)
              @current_phase = :triage
              triage_result = run_triage_with_retries(
                cfg, ctx_pass, task, pass: pass,
                started_at: started_at, max_wall_clock_sec: max_wall_clock
              )
              if triage_result == :wall_clock_exceeded
                return finalize_wall_clock_stale(task, started_at, pass: pass)
              end

              case triage_result.status
              when :tampered
                Hive::Markers.set(task.state_file, :review_error,
                                  phase: :triage, reason: "triage_tampered",
                                  files: triage_result.tampered_files.join(","), pass: pass)
                return { commit: "triage_tampered_pass_#{format('%02d', pass)}",
                         status: :review_error }
              when :error
                limited = mark_review_phase_failure(
                  task, phase: :triage, terminal_reason: "triage_failed",
                  pass: pass, error_message: triage_result.error_message
                )
                label = limited ? "triage_limits_reached" : "triage_error"
                return { commit: "#{label}_pass_#{format('%02d', pass)}",
                         status: :review_error }
              end
            else
              write_manual_escalations(ctx_pass)
            end
            publish_escalations(task, cfg, pass)
          end

          # Branch on triage output. Read per-reviewer files for [x]
          # count (source of truth). escalations file existence + line
          # count tells us whether anything was escalated.
          accepted_findings = collect_accepted_findings_with_count(ctx_pass)
          accepted = accepted_findings.text
          escalations_count = count_escalations(ctx_pass)

          if accepted.strip.empty? && escalations_count.zero?
            # Mixed reviewer success/failure must not silently
            # auto-complete. If errors-NN.md exists
            # (at least one reviewer's adapter failed in this pass),
            # the all-clean signal from the surviving reviewers is
            # NOT proof that the worktree is clean — it only proves
            # the reviewers that ran found nothing. Surface as a
            # recoverable REVIEW_ERROR rather than REVIEW_WAITING:
            # no user answer is required; the right default action is
            # clearing the error marker and rerunning reviewers.
            errors_path = File.join(
              ctx_pass.task_folder,
              "reviews",
              "errors-#{format('%02d', pass)}.md"
            )
            if File.exist?(errors_path)
              Hive::Markers.set(task.state_file, :review_error,
                                phase: :reviewers,
                                reason: "reviewer_partial_failure",
                                pass: pass)
              return { commit: "review_error_reviewer_partial_failure_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end

            # Phase 2 produced zero findings → skip Phase 4, jump to Phase 5.
            # Mark the pass complete so a subsequent run that re-enters this
            # task (e.g. wall-clock-stale fired before Phase 5 records
            # REVIEW_COMPLETE) doesn't classify the no-fix-needed pass as
            # "fix incomplete" and try to retry it.
            write_fix_success(ctx_pass)
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
          pre_fix_status = prepare_worktree_for_fix(task, cfg, worktree_path)
          case pre_fix_status
          when :dirty
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix,
                              reason: "fix_dirty_worktree",
                              message: "worktree was dirty before fix agent; refusing to auto-commit pre-existing changes",
                              pass: pass)
            return { commit: "fix_dirty_worktree_pass_#{format('%02d', pass)}",
                     status: :review_error }
          when Array
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix,
                              reason: "fix_status_check_failed",
                              message: truncate_marker_message(pre_fix_status[1]),
                              pass: pass)
            return { commit: "fix_status_check_failed_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          # Protect orchestrator-owned files PLUS the current pass's
          # escalations doc — only Triage may write that file, so a fix
          # agent rewriting it (e.g. flipping `[ ]` → `[x]` to short-
          # circuit human review) trips fix_tampered.
          #
          # U5 — also protect reviews/fix-guardrail-NN.md: it does not
          # exist yet when this snapshot runs (the runner only writes
          # it AFTER the fix-agent spawn if the guardrail trips). A
          # compromised fix agent that pre-creates an all-`[x]` file
          # to stage an approval token for the next resume would trip
          # fix_tampered. The orchestrator's own legitimate write via
          # write_fix_guardrail_findings happens AFTER after_fix_sha
          # is captured, so it is unaffected.
          protected_set = FIX_PROTECTED_FILES + [
            "reviews/escalations-#{format('%02d', pass)}.md",
            "reviews/fix-guardrail-#{format('%02d', pass)}.md",
            # reviews/errors-NN.md is the orchestrator-owned record of
            # reviewer infra failures from this pass. A
            # fix agent rewriting or deleting it would erase the failure
            # provenance the user relies on for triage.
            "reviews/errors-#{format('%02d', pass)}.md",
            fix_success_relative_path(pass)
          ]
          before_fix_sha = Hive::ProtectedFiles.snapshot(task.folder, protected_set)
          before_fix_head = git_head(worktree_path)

          fix_result = spawn_fix_agent(task, cfg, ctx_pass, accepted: accepted)
          after_fix_sha = Hive::ProtectedFiles.snapshot(task.folder, protected_set)
          after_fix_head = git_head(worktree_path)

          if (tampered = Hive::ProtectedFiles.diff(before_fix_sha, after_fix_sha)).any?
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix, reason: "fix_tampered",
                              files: tampered.join(","), pass: pass)
            return { commit: "fix_tampered_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          if agent_failed?(fix_result)
            limited = mark_review_phase_failure(
              task, phase: :fix, terminal_reason: "fix_failed",
              pass: pass, error_message: fix_result && fix_result[:error_message]
            )
            label = limited ? "fix_limits_reached" : "fix_error"
            return { commit: "#{label}_pass_#{format('%02d', pass)}",
                     status: :review_error }
          end

          post_fix_status = worktree_status(worktree_path)
          case post_fix_status
          when :dirty
            auto_commit = auto_commit_fix_worktree(task, cfg, ctx_pass, accepted_findings)
            unless auto_commit[:success]
              reason = auto_commit[:reason] || "fix_auto_commit_failed"
              attrs = {
                phase: :fix,
                reason: reason,
                message: truncate_marker_message(auto_commit[:message]),
                pass: pass
              }
              attrs[:files] = auto_commit[:files] if auto_commit[:files]
              Hive::Markers.set(task.state_file, :review_error, **attrs)
              return { commit: "#{reason}_pass_#{format('%02d', pass)}",
                       status: :review_error }
            end

            after_fix_head = auto_commit[:head]
          when Array
            Hive::Markers.set(task.state_file, :review_error,
                              phase: :fix, reason: "fix_status_check_failed",
                              message: truncate_marker_message(post_fix_status[1]),
                              pass: pass)
            return { commit: "fix_status_check_failed_pass_#{format('%02d', pass)}",
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
            # Record the guarded HEAD SHA on the marker so the
            # approval-on-resume path can verify the
            # commits the user is approving still match the diff the
            # guardrail flagged. Without this, a user (or an automated
            # editor) who amends/squashes/rebases the worktree between
            # the trip and the approval can launder a different diff
            # past the guardrail using stale [x] ticks.
            Hive::Markers.set(task.state_file, :review_waiting,
                              reason: "fix_guardrail",
                              matches: guardrail.matches.size,
                              head: after_fix_head,
                              pass: pass)
            return { commit: "review_waiting_fix_guardrail_pass_#{format('%02d', pass)}",
                     status: :review_waiting }
          end

          # Phase 4 fix succeeded AND guardrail passed: pass N is
          # complete. Drop the sentinel so a subsequent re-entry (e.g.
          # wall-clock fired between this point and the next pass's
          # reviewers) recognises pass N as done and advances to N+1
          # rather than retrying the fix on already-applied [x] marks.
          write_fix_success(ctx_pass)

          break if pass >= max_passes

          # On the next iteration, treat as fresh entry (not waiting-
          # resume / fix-retry). fix_retry_pass only ever applies to
          # the very first iteration after entry; once we've executed
          # a clean Phase 4 and incremented, we're on a brand-new pass.
          marker = Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
          fix_retry_pass = nil
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
      rescue Hive::ConfigError => e
        # A Hive::ConfigError
        # (e.g. `max_review_pass NN=99 exceeds review.max_passes=4`) is
        # a typed, actionable failure with a helpful message. The
        # generic StandardError rescue below would re-classify it as
        # `reason=runner_exception exception_class=Hive::ConfigError`,
        # discarding the message. Surface it as a config-phase error
        # marker that preserves the message in the `reason` attr.
        Hive::Markers.set(task.state_file, :review_error,
                          phase: @current_phase || :pre_flight,
                          reason: "config_error",
                          message: e.message)
        raise
      rescue Hive::AgentError => e
        raise unless Hive::ClaudeLauncher.tmux_unavailable_error?(e)

        Hive::Markers.set(task.state_file, :review_error,
                          phase: @current_phase || :pre_flight,
                          reason: "tmux_unavailable",
                          message: e.message)
        { commit: "review_error_tmux_unavailable", status: :review_error }
      rescue StandardError => e
        # Any uncaught helper exception would otherwise leave a stale
        # REVIEW_WORKING marker on disk. Translate to REVIEW_ERROR with
        # the best-known phase so the user (and `hive run --json`) sees
        # the failure state, then re-raise so the runner / test suite
        # still surfaces the underlying bug.
        #
        # Truncate `e.message` to a bounded length: when a helper
        # (e.g. `prepare_claude_session!`) raises with a pane-tail
        # context, that tail is the single most actionable debug signal
        # for the operator. Dropping the message entirely (the previous
        # `exception_class`-only marker) silently hid it.
        Hive::Markers.set(task.state_file, :review_error,
                          phase: @current_phase || :pre_flight,
                          reason: "runner_exception",
                          exception_class: e.class.name,
                          message: truncate_marker_message(e.message))
        raise
      ensure
        # Close the last open phase event on any exit path (return,
        # rescue, SystemExit) so the events.jsonl bracket structure
        # stays balanced. Swallow failures here — a torn events file
        # must not mask the underlying control-flow result/exception.
        close_phase_event!(task) if @open_phase_event
      end

      # Marker attr values are scanned by `hive status --json` and read by
      # the TUI; an unbounded multi-kilobyte tail in a single attr would
      # break the line-oriented marker format. 500 bytes is the same cap
      # `prepare_claude_session!` uses for its own tail capture.
      def truncate_marker_message(message, max: 500, ellipsis: "...")
        return "" if message.nil?

        s = message.to_s
        s.length <= max ? s : "#{s[0, max - ellipsis.length]}#{ellipsis}"
      end

      # --- helpers ---------------------------------------------------------

      def canonical_worktree_root(task, cfg)
        cfg["worktree_root"] || Hive::Worktree.default_worktree_root(File.basename(task.project_root))
      end

      # Resolve the ref reviewers diff against, preferring an explicit
      # configured value, then falling back to the project's origin
      # default branch (derived from origin/HEAD or origin/main/master).
      # Fails preflight when no explicit config and no trusted source —
      # silently falling back to the worktree's current branch would
      # make reviewers diff the task branch against itself (zero or
      # phantom findings).
      #
      # Remote-tracking ref existence is probed via the full
      # `refs/remotes/origin/<branch>` path so a tag named e.g.
      # `origin/main` cannot satisfy the check.
      def reviewer_compare_ref(cfg, ops)
        configured = cfg["default_branch"].to_s.strip
        unless configured.empty?
          return configured if configured.start_with?("origin/")

          return resolve_remote_or_local(ops, configured)
        end

        origin = ops.origin_default_branch
        if origin.nil?
          warn "hive: reviewer compare ref unavailable — set `default_branch` in .hive-state/config.yml " \
               "or run `git -C <project_root> remote set-head origin --auto` so origin/HEAD points at " \
               "the project's default branch (refusing to fall back to the worktree's current branch)"
          exit 1
        end

        resolve_remote_or_local(ops, origin)
      end

      def resolve_remote_or_local(ops, branch)
        return "origin/#{branch}" if ops.ref_exists?("refs/remotes/origin/#{branch}")

        warn "[hive] origin/#{branch} not found in worktree; reviewers will compare against local #{branch} (diffs may be stale)"
        branch
      end

      def mark_working(task, phase:, pass:)
        Hive::Markers.set(task.state_file, :review_working, phase: phase, pass: pass)
        # Bracket the phase with agent_start/agent_end so the drill-down
        # view can show "review pass=2 — fix" and the per-reviewer
        # spawn brackets nest cleanly under it. Reviewer spawns
        # additionally emit their own agent_start/agent_end via
        # Hive::Agent#run! — those use the profile name + log_label
        # ("claude review-stub-reviewer-pass01") and are distinguishable
        # from the phase-level pair ("phase=reviewers pass=01").
        close_phase_event!(task) if @open_phase_event
        label = "phase=#{phase} pass=#{format('%02d', pass)}"
        @open_phase_event = {
          task: task,
          label: label,
          stage: stage_label_for(task)
        }
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: @open_phase_event[:stage],
          event_type: :agent_start,
          agent: label,
          message: "phase=#{phase}"
        )
      end

      def close_phase_event!(_task = nil)
        return unless @open_phase_event

        open = @open_phase_event
        @open_phase_event = nil
        Hive::Events.emit(
          task_folder: open[:task].folder,
          slug: open[:task].slug,
          stage: open[:stage],
          event_type: :agent_end,
          agent: open[:label],
          message: "phase complete"
        )
      rescue SystemCallError, IOError, JSON::JSONError
        # Closing the phase event must never mask the underlying control
        # flow's result on a torn events file. Narrow rescue lets genuine
        # call-site bugs (NoMethodError, NameError, ArgumentError) surface.
        nil
      end

      def stage_label_for(task)
        Hive::Stages::Base.stage_label(task)
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

      # A per-pass review-phase agent (triage, fix) that died because the
      # provider hit a usage/credit limit must self-heal like the reviewers
      # phase already does — not sit terminally red until a human retries.
      # When the captured error text reads as a limit, stamp
      # `reason: limits_reached` plus a `retry_after` cooldown the daemon
      # healer honors (StaleAgentHealer#auto_recoverable_review_error?);
      # otherwise write the terminal `<phase>_failed` marker as before.
      # A timeout (no limit text) stays terminal — only an actual limit
      # earns the self-healing retry stamp. Returns whether the limit path
      # was taken so the caller can label its commit.
      def mark_review_phase_failure(task, phase:, terminal_reason:, pass:, error_message:)
        if Hive::AgentLimit.limit_reached?(error_message.to_s)
          Hive::Markers.set(task.state_file, :review_error,
                            phase: phase, reason: "limits_reached", pass: pass,
                            message: "#{phase} hit a usage/credit limit",
                            retry_after: Hive::AgentLimit.retry_after)
          true
        else
          Hive::Markers.set(task.state_file, :review_error,
                            phase: phase, reason: terminal_reason, pass: pass,
                            message: review_phase_error_summary(error_message))
          false
        end
      end

      # Condense a phase agent's `error_message` into a single-line marker
      # attribute. Without this, a terminal review_error records only a bare
      # `reason=triage_failed` / `reason=fix_failed` and the real cause (a tmux
      # session death, an "expected output missing" timeout, a CLI crash) is
      # discarded — so `status.md`, `hive status --json`, and the web
      # diagnostic card all show a contentless "the stage hit an error" with
      # nothing to act on. Surfacing it turns an opaque failure into a
      # diagnosable one. nil/blank collapses to no attr (Markers.set compacts
      # nil values); multi-line / quote / comment-marker content is sanitized
      # downstream by Hive::Markers.format_attr.
      def review_phase_error_summary(error_message)
        text = error_message.to_s.strip.gsub(/\s+/, " ")
        return nil if text.empty?

        # Reuse the shared marker-message truncator (one implementation), but
        # with this surface's own cap and single-char ellipsis. Distinct from
        # the default-cap callers: this collapses to a single line and returns
        # nil (not "") on blank so the message= attr is omitted entirely.
        truncate_marker_message(text, max: REVIEW_PHASE_ERROR_SUMMARY_MAX, ellipsis: "…")
      end

      # Run the triage phase with a bounded retry budget, mirroring the
      # per-reviewer retry in Hive::Reviewers::Agent. Triage drives an
      # interactive agent over tmux; on a loaded host a single transient
      # infra blip (a momentary `tmux has-session` failure misread as
      # "session terminated", an "expected output missing" timeout) used to
      # fail triage outright and park the task in 6-review with a terminal
      # `triage_failed` marker that the daemon never auto-retries. Retrying
      # the same transient class that reviewers already retry keeps an infra
      # flake from sticking the whole task.
      #
      # Non-retryable outcomes return immediately:
      #   - :ok        — nothing to retry.
      #   - :tampered  — the agent touched protected files; a retry repeats
      #                  the violation rather than curing it.
      #   - usage/credit limit — mark_review_phase_failure stamps it as
      #                  limits_reached + retry_after for the daemon to
      #                  self-heal once the window resets; burning inline
      #                  attempts against an active limit only wastes budget.
      def run_triage_with_retries(cfg, ctx_pass, task, pass:, started_at:, max_wall_clock_sec:)
        max_attempts = triage_max_attempts(cfg)
        attempt = 0
        loop do
          attempt += 1
          mark_working(task, phase: :triage, pass: pass)
          result = Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: ctx_pass)

          return result if result.status == :ok
          return result if result.status == :tampered
          return result if Hive::AgentLimit.limit_reached?(result.error_message.to_s)
          return result if attempt >= max_attempts

          # Don't start another full triage spawn (timeout_sec default 1800s) if
          # the review wall-clock budget is already spent — mirrors run_reviewers
          # so a high max_attempts can't overrun review.max_wall_clock_sec. The
          # caller turns this into REVIEW_STALE reason=wall_clock.
          return :wall_clock_exceeded if wall_clock_exceeded?(started_at, max_wall_clock_sec)

          triage_retry_backoff(attempt)
        end
      end

      # Attempt budget for the triage phase. Defaults to the shared reviewer
      # budget; override per project via `review.triage.max_attempts` (1
      # disables retry — single attempt).
      def triage_max_attempts(cfg)
        value = cfg.dig("review", "triage", "max_attempts")
        return Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS if value.nil?

        [ Integer(value), 1 ].max
      rescue ArgumentError, TypeError, RangeError
        # Config::POSITIVE_INTEGER_KEYS rejects a bad value at load time, but
        # programmatic/test configs bypass that gate. Mirror the reviewer
        # adapters (Hive::Reviewers::Agent#max_attempts_from_spec): warn and fall
        # back rather than aborting the whole 6-review run with a runner_exception.
        # RangeError covers Integer(Float::INFINITY)/Integer(Float::NAN), which
        # raise FloatDomainError (a RangeError, NOT an ArgumentError/TypeError).
        warn "hive: invalid review.triage.max_attempts=#{value.inspect}; " \
             "using default #{Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS}"
        Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS
      end

      # Exponential backoff (1s, 2s, 4s, …) between failed triage attempts,
      # capped like the reviewer adapters via the shared
      # Hive::Reviewers.backoff_seconds_for. Kept as a thin seam so tests stub it.
      def triage_retry_backoff(failed_attempt)
        sleep(Hive::Reviewers.backoff_seconds_for(failed_attempt))
      end

      # Pass to start at on a fresh hive run. Falls back to 1 when no
      # reviewer files exist yet.
      def next_pass_for(task, marker, cfg = nil)
        max = max_review_pass(task.folder, cfg)
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
          # Retry pass N when it's not yet complete (either triage
          # didn't write escalations-NN.md, or fix didn't finish before
          # the runner exited / was interrupted). pass_completion_status
          # returns :complete, :triage_incomplete, or :fix_incomplete.
          pass_completion_status(task.folder, max) == :complete ? max + 1 : max
        end
      end

      # Classify whether a pass is fully complete on disk. Used by both
      # next_pass_for (decide retry vs advance) and the loop body
      # (decide whether to run Phase 2/3 again or skip straight to
      # Phase 4 on a fix retry).
      #
      # Returns one of:
      #   :complete           — reviewer files for pass N+1 exist OR a
      #                         `fix-success-NN.md` sentinel exists AND
      #                         the operator has not edited escalations
      #                         since; the runner moved past pass N cleanly.
      #   :triage_incomplete  — reviewer files for pass N exist but no
      #                         `escalations-NN.md`, or escalations exist
      #                         without a completed fix while
      #                         `errors-NN.md` records reviewer infra
      #                         failures for the pass. Retry runs Phase
      #                         2/3 so failed reviewers get a fresh
      #                         attempt and stale errors are cleared. A
      #                         pass with a fresh `fix-success-NN.md` stays
      #                         `:complete` even if `errors-NN.md` lingers,
      #                         so an already-fixed pass is never re-run.
      #   :fix_incomplete     — reviewer files AND escalations-NN.md
      #                         exist, but neither the fix-success
      #                         sentinel nor any pass-N+1 reviewer file
      #                         exists, OR the operator edited
      #                         escalations-NN.md after fix-success-NN.md
      #                         was written. Fix-phase failed
      #                         (REVIEW_ERROR phase=fix), was interrupted
      #                         mid-fix, or the operator's edits supersede
      #                         the previous fix. Retry skips Phase 2/3
      #                         and re-runs Phase 4 on the operator's
      #                         current [x] marks.
      #
      # Pass < 1 or an empty reviews/ dir → :complete (nothing to retry).
      def pass_completion_status(task_folder, pass)
        return :complete if pass < 1

        pass_suffix = format("%02d", pass)
        reviews_dir = File.join(task_folder, "reviews")
        reviewer_files = Dir[File.join(reviews_dir, "*-#{pass_suffix}.md")]
                          .select { |path| reviewer_file?(File.basename(path)) }
        return :complete if reviewer_files.empty?

        escalations_path = File.join(reviews_dir, "escalations-#{pass_suffix}.md")
        errors_path = File.join(reviews_dir, "errors-#{pass_suffix}.md")

        unless File.exist?(escalations_path)
          # No triage escalations yet (this includes the empty-findings
          # partial-failure case, which writes no escalations). Retry Phase
          # 2/3; an errors-NN.md here just means some reviewers also need a
          # fresh attempt.
          return :triage_incomplete
        end

        # Triage produced escalations. A fresh fix-success sentinel means the
        # pass is complete — even if errors-NN.md lingers from a partial
        # reviewer failure earlier in the same pass. This check must come
        # BEFORE the errors-NN.md retry below: otherwise an already-fixed
        # pass that also carries errors-NN.md would re-run reviewers and
        # clobber the operator's [x] marks (regression guarded here).
        fix_success = fix_success_path(task_folder, pass)
        return :complete if fix_success_fresh?(fix_success, escalations_path)

        # Escalations exist but the fix isn't done. If reviewers recorded
        # infra failures this pass, retry Phase 2/3 so they get a fresh
        # attempt and the stale errors-NN.md is cleared.
        return :triage_incomplete if File.exist?(errors_path)

        next_pass_suffix = format("%02d", pass + 1)
        next_pass_started = Dir[File.join(reviews_dir, "*-#{next_pass_suffix}.md")].any? do |path|
          reviewer_file?(File.basename(path))
        end
        return :complete if next_pass_started

        :fix_incomplete
      end

      def fix_success_fresh?(fix_success_path, escalations_path)
        return false unless File.exist?(fix_success_path)

        File.mtime(fix_success_path) >= File.mtime(escalations_path)
      rescue SystemCallError, IOError
        true
      end

      # Back-compat shim: PR #56 named the narrower predicate this. Now
      # derived from pass_completion_status so the broader fix-incomplete
      # case routes through one source of truth.
      def incomplete_triage_pass?(task_folder, pass)
        pass_completion_status(task_folder, pass) == :triage_incomplete
      end

      def resuming_from_waiting?(marker, pass)
        marker.name == :review_waiting &&
          marker.attrs["pass"].to_i == pass
      end

      def max_review_pass(task_folder, cfg = nil)
        glob = File.join(task_folder, "reviews", "*-*.md")
        max = 0
        offending = nil
        Dir[glob].each do |path|
          name = File.basename(path)
          next unless reviewer_file?(name)

          if name =~ /-(\d{2})\.md\z/
            n = Regexp.last_match(1).to_i
            if n > max
              max = n
              offending = path
            end
          end
        end

        # Defend against hostile / stale `*-99.md` files by capping at
        # max_passes + 1. A user manually editing a reviewer file with
        # a wildly higher NN would otherwise drive the loop past
        # `review.max_passes` and overwrite real findings.
        max_passes = cfg ? (cfg.dig("review", "max_passes") || 4) : nil
        if max_passes && max > max_passes + 1
          raise Hive::ConfigError,
                "review pass NN=#{max} exceeds review.max_passes=#{max_passes}; remove or rename #{offending}"
        end

        max
      end

      # Run every configured reviewer sequentially. Returns :all_failed
      # if every reviewer's adapter returned :error; :ok when at least
      # one succeeded; :ok also when specs is empty (no reviewers
      # configured = nothing to triage; loop proceeds to Phase 5 via
      # the all-clean branch).
      #
      # Per-reviewer failures land in `reviews/errors-NN.md` (a new
      # orchestrator-owned sink — see ORCHESTRATOR_OWNED_PREFIXES)
      # instead of being written to the reviewer's own per-pass output
      # file. This keeps `reviewer_file?` truthful (if a reviewer file
      # exists, it has real findings the triage agent should read) and
      # gives the user a single grep-target for infra failures separate
      # from real escalations.
      # Run every reviewer for the current pass. Returns one of:
      #   :ok                  — at least one reviewer succeeded
      #   :all_failed          — every reviewer returned :error
      #   :wall_clock_exceeded — caller's wall-clock budget elapsed
      #                          mid-loop; remaining reviewers skipped
      #
      # The wall-clock check covers adapter-local retry (max_attempts ×
      # timeout_sec × reviewer count) that can otherwise exhaust
      # max_wall_clock_sec entirely inside this method before the outer
      # phase-boundary check fires. With the budget threaded through,
      # we short-circuit between reviewers as soon as the budget is
      # gone — the partial results stay on disk for the next run to
      # consume.
      def run_reviewers(cfg, ctx, task, started_at: nil, max_wall_clock_sec: nil)
        specs = reviewer_specs_for(cfg, task)

        # Clear stale errors-NN.md BEFORE any early return. The docs
        # promise "errors-NN.md reflects
        # the current invocation's failures (or its absence reflects
        # all-success)"; an empty-spec early return that skipped the
        # cleanup violated that contract when a project removed all
        # reviewers between runs.
        clear_reviewer_infra_errors(ctx)

        if specs.empty?
          # An empty NORMAL review.reviewers is an intentional opt-out, but a
          # patrol task reaching here means patrol.review.reviewers resolved
          # to [] — the patrol PR would clear 6-review with no reviewer run.
          # That is operator-surprising, so make it observable rather than
          # letting the review gate pass silently.
          if patrol_task?(task)
            warn "[hive.review] patrol task resolved to zero patrol.review.reviewers; " \
                 "6-review will pass with no reviewers run — set patrol.review.reviewers " \
                 "in .hive-state/config.yml to review patrol PRs"
          end
          return :ok
        end
        if started_at && max_wall_clock_sec &&
           wall_clock_exceeded?(started_at, max_wall_clock_sec)
          return :wall_clock_exceeded
        end

        # Track the remaining spec count for legacy adapter compatibility,
        # but modern reviewers receive the full remaining wall-clock budget.
        # Each reviewer's own timeout_sec remains the per-reviewer cap.
        remaining_specs = specs.length

        statuses = []
        # Collect per-reviewer error messages so an all-failed phase can be
        # classified (e.g. every reviewer hit a usage/credit limit) instead of
        # being flattened to a generic "all_failed".
        error_messages = []
        # Partition into claude-tmux specs vs everything else so the
        # shared tmux session covers ONLY the group that needs it: a
        # mixed reviewer list keeps non-claude reviewers running in
        # parallel/headless and limits the session lifetime to the
        # claude run — extra session-open cost was real (preflight +
        # trust prompt + pane setup) for reviewers that did not consume it.
        if shared_claude_reviewer_session?(cfg, specs)
          claude_specs, other_specs = specs.partition { |spec| claude_tmux_reviewer?(cfg, spec) }

          other_specs.each do |spec|
            result = run_reviewer_spec(
              cfg, ctx, spec,
              reviewer_deadline(started_at, max_wall_clock_sec, specs_remaining: remaining_specs),
              started_at: started_at,
              max_wall_clock_sec: max_wall_clock_sec
            )
            return :wall_clock_exceeded if result == :wall_clock_exceeded

            statuses << result.status
            error_messages << result.error_message if result.error?
            handle_reviewer_result(task, cfg, ctx, spec, result)
            remaining_specs -= 1
          end

          return :wall_clock_exceeded if started_at && max_wall_clock_sec &&
                                         wall_clock_exceeded?(started_at, max_wall_clock_sec)

          shared_reviewer_groups(claude_specs).each_with_index do |group, group_idx|
            scope = shared_reviewer_permission_scope(cfg, ctx, task, group.first)
            Hive::ClaudeLauncher.with_shared_session(
              task: task,
              cfg: cfg,
              session_name: shared_reviewer_session_name(task, ctx.pass, group_idx),
              cwd: ctx.worktree_path,
              add_dirs: scope.fetch(:add_dirs),
              allowed_tools: scope.fetch(:allowed_tools),
              disallowed_tools: scope.fetch(:disallowed_tools),
              permission_mode: scope.fetch(:permission_mode)
            ) do |handle|
              group.each do |spec|
                result = run_reviewer_spec(
                  cfg, ctx, spec,
                  reviewer_deadline(started_at, max_wall_clock_sec, specs_remaining: remaining_specs),
                  started_at: started_at,
                  max_wall_clock_sec: max_wall_clock_sec,
                  handle: handle
                )
                return :wall_clock_exceeded if result == :wall_clock_exceeded

                statuses << result.status
                error_messages << result.error_message if result.error?
                handle_reviewer_result(task, cfg, ctx, spec, result)
                remaining_specs -= 1
              end
            end
          end
        else
          specs.each do |spec|
            result = run_reviewer_spec(
              cfg, ctx, spec,
              reviewer_deadline(started_at, max_wall_clock_sec, specs_remaining: remaining_specs),
              started_at: started_at,
              max_wall_clock_sec: max_wall_clock_sec
            )
            return :wall_clock_exceeded if result == :wall_clock_exceeded

            statuses << result.status
            error_messages << result.error_message if result.error?
            handle_reviewer_result(task, cfg, ctx, spec, result)
            remaining_specs -= 1
          end
        end

        return :wall_clock_exceeded if started_at && max_wall_clock_sec &&
                                       wall_clock_exceeded?(started_at, max_wall_clock_sec)

        if statuses.all?(:error)
          # Every reviewer failed. If the failures are usage/credit-limit
          # errors (e.g. codex "you've hit your usage limit"), surface that
          # distinctly so the run is marked limits_reached rather than a
          # generic all_failed.
          if error_messages.any? { |m| Hive::AgentLimit.limit_reached?(m.to_s) }
            :all_failed_limit
          else
            :all_failed
          end
        else
          :ok
        end
      end

      def reviewer_specs_for(cfg, task)
        return Array(cfg.dig("patrol", "review", "reviewers")) if patrol_task?(task)

        Array(cfg.dig("review", "reviewers"))
      end

      def shared_reviewer_groups(specs)
        specs.group_by { |spec| spec.key?("permissions") ? spec["permissions"] : :stage_default }.values
      end

      def shared_reviewer_session_name(task, pass, group_idx)
        suffix = group_idx.zero? ? "" : "-scope#{group_idx + 1}"
        Hive::ClaudeLauncher.tmux_session_name("6-review-pass#{pass}#{suffix}", task)
      end

      def shared_reviewer_permission_scope(cfg, ctx, task, spec)
        profile = Hive::AgentProfiles.lookup(:claude, cfg: cfg)
        kwargs = {
          base_add_dirs: [ ctx.task_folder ],
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        }
        kwargs[:explicit_permission_spec] = spec["permissions"] if spec.key?("permissions")
        Hive::Stages::Base.stage_permission_scope(
          cfg, "review.reviewers", task, profile, **kwargs
        )
      end

      def patrol_task?(task)
        frontmatter = task_frontmatter(task.state_file)
        # Normalize before comparing: the producer (Hive::Patrol::ReviewHandoff)
        # writes a bare lowercase `source: patrol` via to_yaml, but matching
        # exact-case-sensitively means any future producer drift (quoting,
        # casing, trailing whitespace) would silently misroute a patrol PR
        # to the broader normal reviewer set. strip + casecmp? tolerates that.
        frontmatter["source"].to_s.strip.casecmp?("patrol") || false
      rescue SystemCallError => e
        # I/O failures reading task.state_file fall back to the normal
        # reviewer set (the broader, safer direction), but must not be
        # silent — a misrouted patrol PR is otherwise invisible. Psych
        # parse errors are already absorbed by task_frontmatter; narrowing
        # to SystemCallError lets genuine programmer errors (nil task,
        # unknown stage) propagate instead of being swallowed.
        warn "[hive.review] patrol_task? could not read #{task.state_file.inspect}: " \
             "#{e.class}: #{e.message} — routing as a normal (non-patrol) task"
        false
      end

      def task_frontmatter(path)
        return {} unless File.exist?(path)

        content = File.read(path)
        return {} unless content.start_with?("---\n")

        yaml = content.split(/^---\s*$/, 3)[1]
        return {} if yaml.to_s.strip.empty?

        data = YAML.safe_load(yaml, permitted_classes: [ Time ], aliases: false) || {}
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception
        {}
      end

      def reviewer_deadline(started_at, max_wall_clock_sec, specs_remaining:)
        return nil unless started_at && max_wall_clock_sec
        return nil if specs_remaining.to_i <= 0

        remaining = max_wall_clock_sec - (Time.now - started_at)
        return Process.clock_gettime(Process::CLOCK_MONOTONIC) if remaining <= 0

        # Give each reviewer the FULL remaining wall-clock budget; its own
        # `timeout_sec` (default 2h) is the real per-reviewer cap. The old
        # even split (`remaining / specs_remaining`) squeezed each reviewer
        # to a fraction of the budget and killed thorough 1-2h reviewers
        # mid-run with "deadline reached", which then tore down the shared
        # claude session and cascade-failed the rest of the pass.
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + remaining
      end

      def run_reviewer_spec(cfg, ctx, spec, deadline, started_at: nil, max_wall_clock_sec: nil, handle: nil)
        if started_at && max_wall_clock_sec &&
           wall_clock_exceeded?(started_at, max_wall_clock_sec)
          return :wall_clock_exceeded
        end

        adapter = Hive::Reviewers.dispatch(spec, ctx, cfg: cfg)
        # Wrap adapter.run! so a single reviewer raising (spawn-time
        # SystemCallError, network timeout in a custom adapter, …)
        # doesn't abort the whole reviewers phase. Treat as :error,
        # record the failure in errors-NN.md, and continue with the
        # next reviewer.
        # pr-review-toolkit round-4 silent-failure-hunter C2 —
        # feature-detect whether the adapter accepts a `deadline:`
        # kwarg via Method#parameters so we don't have to discriminate
        # ArgumentError-by-message at the rescue site. The previous
        # form (`rescue ArgumentError; adapter.run!`) silently swallowed
        # real adapter bugs that happened to raise ArgumentError from
        # the body (config parsing, Integer() coercion, etc.).
        accepts_deadline = adapter.method(:run!).parameters.any? do |type, name|
          name == :deadline && %i[key keyreq keyrest].include?(type)
        end
        result =
          begin
            if handle
              adapter.run_in_session!(handle: handle, deadline: deadline)
            elsif accepts_deadline
              adapter.run!(deadline: deadline)
            else
              adapter.run!
            end
          rescue Hive::AgentError => e
            # R7: tmux unavailable is a hard-fail for `claude.mode: tmux`,
            # not a per-reviewer infra error. Re-raise so the outer
            # `Stages::Review.run!` rescue lands the dedicated
            # `:review_error reason="tmux_unavailable"` marker instead
            # of recording N per-reviewer errors-NN.md lines and an
            # `:all_failed` envelope.
            raise if Hive::ClaudeLauncher.tmux_unavailable_error?(e)

            Hive::Reviewers::Result.new(
              name: spec["name"],
              output_path: adapter.output_path,
              status: :error,
              error_message: "#{e.class}: #{e.message}"
            )
          rescue StandardError => e
            # A8 fail-closed: a non-yolo permission scope on a reviewer whose
            # runner can't enforce tool scoping (codex / pi) raises
            # Hive::ConfigError from stage_permission_scope. Swallowing it as a
            # per-reviewer :error would let the rest of the pass continue after
            # silently dropping the unenforceable reviewer — a silent security
            # downgrade. Re-raise so the outer `Stages::Review.run!`
            # Hive::ConfigError rescue stamps the `config_error` review_error
            # marker and hard-fails the run. Only the typed config error
            # propagates; genuine per-reviewer infra failures (spawn errors,
            # adapter timeouts) still degrade to a recorded :error below.
            raise if e.is_a?(Hive::ConfigError)

            Hive::Reviewers::Result.new(
              name: spec["name"],
              output_path: adapter.output_path,
              status: :error,
              error_message: "#{e.class}: #{e.message}"
            )
          end
        result
      end

      def handle_reviewer_result(task, cfg, ctx, spec, result)
        if result.error?
          # ce-review round-3 P2 #6 — guarantee the failed adapter
          # leaves no reviewer file behind, even if the adapter
          # raised (Agent#run!'s own final-failure cleanup doesn't
          # run on the rescue path, and custom adapters may not
          # implement it). Deleting unconditionally on the
          # orchestrator side covers both paths uniformly.
          output_path = result.output_path
          File.delete(output_path) if output_path && File.exist?(output_path)

          record_reviewer_infra_error(ctx, spec, result)
        else
          publish_review_file(task, cfg, ctx.pass, spec["name"] || result.name, result.output_path)
        end
      end

      def shared_claude_reviewer_session?(cfg, specs)
        Hive::Config.claude_mode(cfg) == :tmux &&
          specs.any? { |spec| claude_tmux_reviewer?(cfg, spec) }
      end

      def claude_tmux_reviewer?(cfg, spec)
        Hive::Config.claude_mode(cfg) == :tmux &&
          (spec["kind"] || "agent").to_s == "agent" &&
          spec["agent"].to_s == "claude"
      end

      # NOTE: no outer rescue here — `GithubPublisher.publish!` has
      # its own narrow rescue and returns `:failed` for the categories
      # we want to swallow; a wider rescue here masked NoMethodError
      # / NameError bugs as benign post-failures.
      def publish_review_file(task, cfg, pass, reviewer_name, body_path)
        Hive::Stages::Review::GithubPublisher.publish!(
          task,
          pass: pass,
          reviewer_name: reviewer_name,
          body_path: body_path,
          cfg: cfg
        )
      end

      def publish_escalations(task, cfg, pass)
        path = File.join(task.reviews_dir, "escalations-#{format('%02d', pass)}.md")
        return unless File.exist?(path)
        return unless File.readlines(path).any? { |line| line =~ /^\s*-\s+\[\s*\]\s+/ }

        Hive::Stages::Review::GithubPublisher.publish!(
          task,
          pass: pass,
          reviewer_name: "escalations",
          body_path: path,
          cfg: cfg
        )
      end

      # Remove any stale `reviews/errors-NN.md` from a prior
      # invocation of this pass. Called once at the start of
      # `run_reviewers` so the file's presence (or absence) always
      # reflects the current invocation's reviewer-failure set, not
      # accumulated history.
      #
      # Try-delete pattern instead of
      # `if File.exist?` to close the TOCTOU window (another process
      # could delete the file between the check and the delete on a
      # networked FS). ENOENT after that race is the expected
      # outcome — swallow it. Other SystemCallError values (EACCES on
      # parent dir, EROFS) get re-raised as a named error so a
      # downstream `runner_exception` re-classification doesn't hide
      # the real cause (read-only mount, perms misconfig).
      def clear_reviewer_infra_errors(ctx)
        path = File.join(
          ctx.task_folder,
          "reviews",
          "errors-#{format('%02d', ctx.pass)}.md"
        )
        File.delete(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Hive::Error,
              "failed to clear stale #{path}: #{e.class}: #{e.message}"
      end

      # Append one infra-error line to reviews/errors-NN.md. The file
      # is initialized with a header on first write per invocation;
      # subsequent failures append. Per-invocation freshness is
      # guaranteed by `clear_reviewer_infra_errors` at the top of
      # `run_reviewers` — this helper itself is append-safe across
      # multiple failed reviewers within the same invocation.
      def record_reviewer_infra_error(ctx, spec, result)
        reviews_dir = File.join(ctx.task_folder, "reviews")
        FileUtils.mkdir_p(reviews_dir)
        errors_path = File.join(reviews_dir, "errors-#{format('%02d', ctx.pass)}.md")
        write_header = !File.exist?(errors_path)
        File.open(errors_path, "a") do |f|
          f.write("# Reviewer infra errors for pass #{format('%02d', ctx.pass)}\n\n") if write_header
          f.write(
            "- [#{spec['output_basename']}] reviewer " \
              "#{spec['name'].inspect} failed: #{result.error_message}\n"
          )
        end
      rescue SystemCallError => e
        # This file is load-bearing for the U2 contract and for the
        # reviewer_partial_failure pause path. If the write fails
        # (ENOSPC, EROFS, EACCES on a shared mount, EDQUOT), the
        # outer run! rescue would classify it as a generic
        # `runner_exception` with no actionable context — and the
        # all-clean branch's File.exist?(errors_path) check would
        # silently auto-complete the pass via write_fix_success.
        # Surface the disk problem explicitly with a named error so
        # the user sees the root cause.
        raise Hive::Error,
              "failed to write reviews/errors-#{format('%02d', ctx.pass)}.md " \
              "for reviewer #{spec['name'].inspect}: #{e.class}: #{e.message}"
      end

      # All [x] lines across every per-reviewer file for the current
      # pass, concatenated. Used by Phase 4's fix-agent prompt.
      def collect_accepted_findings(ctx)
        collect_accepted_findings_with_count(ctx).text
      end

      def collect_accepted_findings_with_count(ctx)
        out = +""
        count = 0
        Dir[File.join(ctx.task_folder, "reviews", "*-#{format('%02d', ctx.pass)}.md")].sort.each do |path|
          name = File.basename(path)
          next unless reviewer_file?(name)

          File.readlines(path).each do |line|
            next unless auto_fix_finding_line?(line)

            out << "[#{name}] #{line}"
            count += 1
          end
        end

        answered = collect_answered_escalation_findings_with_count(ctx)
        out << answered.text
        AcceptedFindings.new(text: out, count: count + answered.count)
      end

      def auto_fix_finding_line?(line)
        return false unless line =~ /^\s*-\s+\[x\]\s+/
        return false if line =~ /^\s*-\s+\[x\]\s+(RESOLVED\/NO-FIX|RESOLVED|NO-FIX)\b/i

        true
      end

      def collect_answered_escalation_findings(ctx)
        collect_answered_escalation_findings_with_count(ctx).text
      end

      def collect_answered_escalation_findings_with_count(ctx)
        path = Hive::Stages::Review::Triage.escalations_path(ctx)
        questions = parse_escalation_questions(path)
        return collect_legacy_checked_escalations_with_count(path) if questions.empty?

        answered = questions.select { |q| q[:answer].strip != "" }
        return AcceptedFindings.new(text: "", count: 0) if answered.empty?

        name = File.basename(path)
        out = +"\n# User answers from #{name}\n"
        answered.each do |q|
          out << "[#{name}] USER-ANSWERED ESCALATION Q#{q[:number]}: #{q[:question]}\n"
          body = q[:body].strip
          out << answered_escalation_context_block(name, body) unless body.empty?
          out << "[#{name}] Answer:\n"
          out << answered_escalation_context_block(name, q[:answer].strip)
          out << "\n"
        end
        AcceptedFindings.new(text: out, count: answered.size)
      end

      def collect_legacy_checked_escalations(path)
        collect_legacy_checked_escalations_with_count(path).text
      end

      def collect_legacy_checked_escalations_with_count(path)
        return AcceptedFindings.new(text: "", count: 0) unless File.exist?(path)

        name = File.basename(path)
        lines = File.readlines(path).select { |line| auto_fix_finding_line?(line) }
        return AcceptedFindings.new(text: "", count: 0) if lines.empty?

        out = +"\n# Accepted legacy escalations from #{name}\n"
        lines.each { |line| out << "[#{name}] #{line}" }
        AcceptedFindings.new(text: out, count: lines.size)
      rescue SystemCallError, IOError
        AcceptedFindings.new(text: "", count: 0)
      end

      def answered_escalation_context_block(name, text)
        text.lines(chomp: true).map { |line| "[#{name}] >>> #{line}\n" }.join
      end

      def count_escalations(ctx)
        path = Hive::Stages::Review::Triage.escalations_path(ctx)
        return 0 unless File.exist?(path)

        questions = parse_escalation_questions(path)
        return questions.count { |q| q[:answer].strip.empty? } unless questions.empty?

        File.readlines(path).count { |l| l =~ /^\s*-\s+\[\s*\]\s+/ }
      end

      def parse_escalation_questions(path)
        return [] unless File.exist?(path)

        questions = []
        current = nil
        mode = nil

        File.readlines(path).each do |line|
          if (match = ESCALATION_Q_RE.match(line))
            questions << current if current
            current = {
              number: match[1].to_i,
              question: match[2].strip,
              body: +"",
              answer: +""
            }
            mode = :body
          elsif current && (match = ESCALATION_A_RE.match(line)) && match[1].to_i == current[:number]
            mode = :answer
          elsif current && mode
            current[mode] << line
          end
        end

        questions << current if current
        questions
      rescue SystemCallError, IOError
        []
      end

      def write_manual_escalations(ctx)
        path = Hive::Stages::Review::Triage.escalations_path(ctx)
        reviewer_files = Hive::Stages::Review::Triage.discover_reviewer_files(ctx)
        FileUtils.mkdir_p(File.dirname(path))

        body = +"# Escalations for pass #{format('%02d', ctx.pass)}\n\n"
        body << "_Triage disabled; answer the questions below or edit reviewer files directly._\n\n"
        body << "## Round 1\n\n"

        question = 0

        reviewer_files.each do |reviewer_file|
          findings = File.readlines(reviewer_file).select { |line| line =~ /^\s*-\s+\[\s*\]\s+/ }
          next if findings.empty?

          findings.each do |line|
            question += 1
            body << "### Q#{question}. What should hive do with this reviewer finding?\n"
            body << "Source: #{File.basename(reviewer_file)}\n"
            body << "Finding: #{line.sub(/^\s*-\s+\[\s*\]\s+/, '').strip}\n"
            body << "Context checked: triage disabled\n"
            body << "Why not auto-fixable: triage did not classify this pass\n"
            body << "Suggested default: answer with the desired fix, or say skip/no-fix\n"
            body << "### A#{question}.\n\n"
          end
        end

        body << "_No unchecked reviewer findings found._\n" if question.zero?

        File.write(path, body)
      end

      def spawn_fix_agent(task, cfg, ctx, accepted:)
        profile_name = cfg.dig("review", "fix", "agent") || "claude"
        profile = Hive::AgentProfiles.lookup(profile_name, cfg: cfg)
        scope = Hive::Stages::Base.stage_permission_scope(
          cfg, "review.fix", task, profile,
          base_add_dirs: [ ctx.task_folder ],
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        template = cfg.dig("review", "fix", "prompt_template") || "fix_prompt.md.erb"
        template_path = Hive::Stages::Base.resolve_template_path(
          template,
          hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(ctx.task_folder)
        )

        prompt = Hive::Stages::Base.render_resolved_path(
          template_path,
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

        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: ctx.worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "review_fix") || 100,
          timeout_sec: cfg.dig("timeout_sec", "review_fix") || 2700,
          log_label: "review-fix-pass#{format('%02d', ctx.pass)}",
          profile: profile,
          permission_mode: scope.fetch(:permission_mode),
          allowed_tools: scope.fetch(:allowed_tools),
          disallowed_tools: scope.fetch(:disallowed_tools),
          status_mode: :exit_code_only
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("6-review-fix-pass#{ctx.pass}", task)
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
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
                  .select { |n| reviewer_file?("#{n}.md") }
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

          The 6-review CI-fix loop hit `review.ci.max_attempts` without a green CI.
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

        # Group findings by severity so the user
        # cannot accidentally approve a high-severity edit by reading
        # only the medium/low ones. Each severity becomes a labelled
        # ## section; approval semantic stays all-`[x]` per file but
        # the layout forces explicit acknowledgement of each tier.
        # Severity is `:high | :medium | :nit` per Patterns::DEFAULTS;
        # render order high → medium → nit.
        severity_order = %i[high medium nit]
        section_labels = {
          high: "## High — auto-fix forbidden; tick `[x]` only after inspecting the diff",
          medium: "## Medium",
          nit: "## Nit"
        }
        grouped = matches.group_by do |m|
          severity_order.include?(m.severity) ? m.severity : :nit
        end
        severity_order.each do |severity|
          entries = grouped[severity]
          next if entries.nil? || entries.empty?

          body << "#{section_labels[severity]}\n\n"
          entries.each do |m|
            body << "- [ ] #{m.pattern_name}: #{m.file}:#{m.line || '?'}: #{m.snippet}\n"
          end
          body << "\n"
        end
        File.write(path, body)
      end

      # U5 — check whether reviews/fix-guardrail-NN.md has been
      # user-approved for the given pass. Approved = every checkbox
      # line is `[x]` AND (when `expected_matches:` is supplied) the
      # checkbox count matches what the runner originally wrote.
      # Returns false for: file absent, header-only file (zero
      # checkbox lines), any `[ ]` remaining, or count mismatch.
      #
      # The checkbox regex matches `- [ ]` and `- [x]` lines (case-
      # insensitive on the `x`); other line shapes (the title, blank
      # lines, any free-form prose under it) are ignored.
      #
      # `expected_matches:`: the orchestrator
      # supplies the original match count from `marker.attrs["matches"]`
      # so we reject approval when the file's checkbox count differs —
      # defends against a "truncation-forged" approval where the user
      # deletes the findings they didn't want to read and ticks `[x]`
      # only on the remaining one. The orchestrator hard-rejects
      # markers with non-Integer `matches` upstream (see the
      # `malformed_marker_matches` branch in run!), so production
      # callers always pass a positive Integer here. `nil` is for
      # direct unit tests only; passing `nil` from production code
      # disables the truncation defense and is a bug.
      #
      # Caller invariant: only consult this when the resume marker is
      # `:review_waiting reason=fix_guardrail` for the same pass. The
      # helper itself does not check the marker — it is a pure file
      # inspector. The orchestrator guards the call site.
      def fix_guardrail_approved?(ctx, expected_matches: nil)
        path = File.join(
          ctx.task_folder,
          "reviews",
          "fix-guardrail-#{format('%02d', ctx.pass)}.md"
        )
        return false unless File.exist?(path)

        checkbox_re = /^\s*-\s+\[([ xX])\]\s+/
        checked_count = 0
        File.foreach(path) do |line|
          next unless (m = line.match(checkbox_re))
          return false if m[1] == " "

          checked_count += 1
        end
        return false if checked_count.zero?
        return false if expected_matches && checked_count != expected_matches

        true
      end

      # Write the per-pass fix-success sentinel. Called from the two
      # "pass N is done, advance" sites: Phase 2's zero-findings break
      # and the post-guardrail-not-tripped continuation. Body is
      # operator-readable; the runner only cares about file presence.
      def write_fix_success(ctx)
        path = fix_success_path(ctx.task_folder, ctx.pass)
        FileUtils.mkdir_p(File.dirname(path))
        body = +"<!-- HIVE: fix-success sentinel for pass " \
               "#{format('%02d', ctx.pass)}; do not edit. " \
               "Removing this file makes the next markerless `hive run` " \
               "treat the pass as fix-incomplete and retry it. -->\n"
        body << "# Fix completed for pass #{format('%02d', ctx.pass)}\n\n"
        body << "Recorded at #{Time.now.utc.iso8601}.\n"
        File.write(path, body)
      end

      def fix_success_relative_path(pass)
        File.join("reviews", "#{FIX_SUCCESS_FILENAME}-#{format('%02d', pass)}.md")
      end

      # The auto-commit primitives (scope-check, sign-policy, commit) now
      # live on Hive::Stages::AutoCommit so the per-pass review fix path and
      # the stage-exit Hive::Stages::CleanExit invariant share one
      # implementation. The shims below preserve the existing in-file call
      # sites without changing their return shapes — module_function methods
      # called as `auto_commit_*` still resolve here, but delegate.
      def git_head(worktree_path)
        Hive::Stages::AutoCommit.git_head(worktree_path)
      end

      def auto_commit_scope_config(cfg)
        Hive::Stages::AutoCommit.auto_commit_scope_config(cfg)
      end

      def auto_commit_scope_check_enabled?(cfg)
        Hive::Stages::AutoCommit.auto_commit_scope_check_enabled?(cfg)
      end

      def staged_auto_commit_paths(worktree_path)
        Hive::Stages::AutoCommit.staged_auto_commit_paths(worktree_path)
      end

      def normalize_staged_path(path)
        Hive::Stages::AutoCommit.normalize_staged_path(path)
      end

      def staged_path_matches_glob?(pattern, path)
        Hive::Stages::AutoCommit.staged_path_matches_glob?(pattern, path)
      end

      def auto_commit_scope_violations(cfg, paths)
        Hive::Stages::AutoCommit.auto_commit_scope_violations(cfg, paths)
      end

      def auto_commit_scope_failure_message(violations)
        Hive::Stages::AutoCommit.auto_commit_scope_failure_message(violations)
      end

      def auto_commit_scope_relative_path(pass)
        File.join("reviews", "#{AUTO_COMMIT_SCOPE_FILENAME}-#{format('%02d', pass)}.md")
      end

      def write_auto_commit_scope_findings(ctx, violations)
        relative = auto_commit_scope_relative_path(ctx.pass)
        path = File.join(ctx.task_folder, relative)
        FileUtils.mkdir_p(File.dirname(path))

        body = +"# Auto-commit scope check failed for pass #{format('%02d', ctx.pass)}\n\n"
        body << "Hive staged the fix-agent changes, rejected the fallback commit, " \
                "and unstaged the index. The files remain in the worktree for operator inspection.\n\n"
        body << "| Path | Reason |\n| --- | --- |\n"
        violations.each do |violation|
          path_cell = violation.path.to_s.gsub("|", "\\|")
          reason_cell = violation.reason.to_s.gsub("|", "\\|")
          body << "| `#{path_cell}` | #{reason_cell} |\n"
        end

        File.write(path, body)
        relative
      end

      def auto_commit_failure_with_unstage(worktree_path, message, **attrs)
        Hive::Stages::AutoCommit.auto_commit_failure_with_unstage(worktree_path, message, **attrs)
      end

      def auto_commit_fix_worktree(task, cfg, ctx, accepted_findings)
        sign_policy = auto_commit_sign_policy_for(cfg)
        sign_policy_failure = auto_commit_sign_policy_failure(ctx.worktree_path, sign_policy)
        return sign_policy_failure if sign_policy_failure

        # `git add -A` (not `-u`) is intentional: fix-agent fixes
        # routinely include new files (added test cases, extracted
        # helpers, new modules) that must land in the same commit as the
        # tracked-file edits they support. Immediately after staging,
        # the auto-commit scope check inspects the exact staged path set
        # before Hive writes its rollback-rate trailers.
        add_out, add_err, add_status = Open3.capture3("git", "-C", ctx.worktree_path, "add", "-A")
        unless add_status.success?
          return auto_commit_failure_with_unstage(
            ctx.worktree_path,
            git_command_message("git add -A", add_out, add_err)
          )
        end

        if auto_commit_scope_check_enabled?(cfg)
          staged = staged_auto_commit_paths(ctx.worktree_path)
          return auto_commit_failure_with_unstage(ctx.worktree_path, staged[:message]) unless staged[:success]

          violations = auto_commit_scope_violations(cfg, staged[:paths])
          unless violations.empty?
            return auto_commit_failure_with_unstage(
              ctx.worktree_path,
              auto_commit_scope_failure_message(violations),
              reason: "fix_auto_commit_scope_failed",
              files: write_auto_commit_scope_findings(ctx, violations)
            )
          end
        end

        message = fix_auto_commit_message(task, cfg, ctx, accepted_findings)
        commit = auto_commit_git_commit(ctx.worktree_path, sign_policy, message)
        unless commit[:success]
          attrs = {}
          reason = auto_commit_commit_failure_reason(sign_policy, commit)
          attrs[:reason] = reason if reason
          return auto_commit_failure_with_unstage(ctx.worktree_path, commit[:message], **attrs)
        end

        { success: true, head: git_head(ctx.worktree_path) }
      end

      def auto_commit_sign_policy_for(cfg)
        Hive::Stages::AutoCommit.auto_commit_sign_policy_for(cfg)
      end

      def auto_commit_sign_policy_failure(worktree_path, sign_policy)
        Hive::Stages::AutoCommit.auto_commit_sign_policy_failure(worktree_path, sign_policy)
      end

      def auto_commit_git_commit(worktree_path, sign_policy, message)
        Hive::Stages::AutoCommit.auto_commit_git_commit(worktree_path, sign_policy, message)
      end

      def auto_commit_commit_failure_reason(sign_policy, commit)
        Hive::Stages::AutoCommit.auto_commit_commit_failure_reason(sign_policy, commit)
      end

      def auto_commit_signing_error?(message)
        Hive::Stages::AutoCommit.auto_commit_signing_error?(message)
      end

      def fix_auto_commit_message(task, cfg, ctx, accepted_findings)
        pass = format("%02d", ctx.pass)
        <<~MSG.chomp
          fix(review): apply pass #{pass} findings

          Hive-Task-Slug: #{task.slug}
          Hive-Fix-Pass: #{pass}
          Hive-Fix-Findings: #{[ accepted_findings.count.to_i, 1 ].max}
          Hive-Triage-Bias: #{sanitize_trailer_value(triage_bias_for(cfg))}
          Hive-Reviewer-Sources: #{sanitize_trailer_value(reviewer_sources_for(ctx))}
          Hive-Fix-Phase: fix
        MSG
      end

      def git_command_message(command, out, err)
        Hive::Stages::AutoCommit.git_command_message(command, out, err)
      end

      def sanitize_trailer_value(value)
        value.to_s.gsub(/[\r\n]+/, " ").strip
      end

      def worktree_dirty?(worktree_path)
        worktree_status(worktree_path) != :clean
      end

      # Returns :clean, :dirty, or [:status_failed, err_message].
      # Distinguishes a transient `git status` failure from "has changes"
      # so the operator gets a true error rather than a misleading
      # fix_dirty_worktree marker.
      def worktree_status(worktree_path)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "status", "--porcelain")
        return [ :status_failed, err.to_s ] unless status.success?

        out.empty? ? :clean : :dirty
      end

      def prepare_worktree_for_fix(task, cfg, worktree_path)
        status = worktree_status(worktree_path)
        return status unless status == :dirty

        cleanup = Hive::Stages::CleanExit.run!(
          worktree_path: worktree_path,
          stage: "6-review", # coding-scoped: coding review stage event
          task: task,
          cfg: cfg,
          reason: :pre_fix_dirty_worktree
        )

        case cleanup[:status]
        when :clean
          :clean
        when :auto_committed
          emit_pre_fix_clean_exit_event(task, cleanup)
          worktree_status(worktree_path)
        when :git_failed
          [ :status_failed, cleanup[:message].to_s ]
        else
          :dirty
        end
      rescue Hive::ConfigError => e
        [ :status_failed, "invalid auto-commit config: #{e.message}" ]
      end

      def emit_pre_fix_clean_exit_event(task, result)
        Hive::Events.emit(
          task_folder: task.folder,
          slug: task.slug,
          stage: "6-review", # coding-scoped: coding review stage event
          event_type: :clean_exit_auto_committed,
          message: "reason=pre_fix_dirty_worktree head=#{result[:head]} paths=#{Array(result[:paths]).join(',')[0, 200]}"
        )
      rescue StandardError
        nil
      end

      def agent_failed?(result)
        return true if result.nil?

        %i[error timeout].include?(result[:status])
      end
    end
  end
end
