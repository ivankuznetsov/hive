require "json"
require "open3"
require "set"
require "yaml"
require "hive/gh"
require "hive/stages/review/publication"
require "hive/stages/review/ci_fix"
require "hive/stages/review/context"
require "hive/stages/review/fix_guardrail"
require "hive/worktree"

module Hive
  module Stages
    module Review
      # Settles the exact GitHub PR head before review may complete. Review
      # fixes happen after the ordinary project CI entry check; without this
      # gate, a fix commit can trigger fresh hosted checks while the task is
      # already moving into artifacts.
      module RemoteCi
        # +reason+ types a mergeability block (see Blocked below); it is
        # nil for ordinary check results and guardrail stops.
        Result = Data.define(
          :status, :attempts, :last_output, :error_message, :limit_text,
          :guardrail, :reason
        ) do
          def initialize(guardrail: nil, reason: nil, **fields)
            super
          end
        end
        # GitHub runs few or no checks on a PR it cannot merge, so a
        # CONFLICTING PR can look green. Mergeability is part of settlement:
        #   base_conflict        -> REVIEW_CI_STALE (operator merges the base)
        #   mergeability_unknown -> REVIEW_ERROR (GitHub never resolved it
        #                           within the bounded wait; fail closed)
        # Required checks are part of settlement too: GitHub may create only
        # some checks (or none) for a head, so "every present check is green"
        # does not prove the base branch's protection is satisfied.
        #   required_checks_missing -> REVIEW_ERROR (a required context never
        #                              reported success on the exact head)
        #   required_checks_unknown -> REVIEW_ERROR (the protection lookup kept
        #                              failing in transport; fail closed)
        Blocked = Data.define(:reason, :detail)
        POLL_INTERVAL_SEC = 10
        QUIET_SETTLEMENT_SEC = 20
        NO_CHECKS_GRACE_SEC = 30
        GREEN_CONCLUSIONS = %w[SUCCESS NEUTRAL SKIPPED].freeze
        FAILURE_CONCLUSIONS = %w[
          FAILURE TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE STALE
        ].freeze
        PENDING_STATUSES = %w[QUEUED PENDING IN_PROGRESS WAITING REQUESTED].freeze
        PENDING_STATES = %w[PENDING EXPECTED].freeze

        module_function

        def run!(task:, cfg:, ctx:, started_at: nil, max_wall_clock_sec: nil,
                 publication_base_head: nil, publication_withheld: nil, runner: nil, no_repair: false, admit_head: nil, publication_observer: nil)
          # An incomplete fix still owes its receipt. Entry CI must leave that
          # recovery to the fix phase rather than publish or repair its HEAD.
          return skipped_result if publication_withheld
          return skipped_result if cfg.dig("review", "github_checks", "enabled") == false

          pr_path = File.join(task.folder, "pr.md")
          return skipped_result unless File.file?(pr_path)

          pr_url = Hive::Gh.pr_frontmatter(pr_path)["pr_url"].to_s
          return skipped_result if pr_url.empty?

          runner ||= Runner.new(
            task: task, cfg: cfg, ctx: ctx, pr_url: pr_url,
            publication_base_head: publication_base_head, publication_withheld: publication_withheld,
            no_repair: no_repair, admit_head: admit_head, publication_observer: publication_observer
          )
          result = Hive::Stages::Review::CiFix.run!(
            cfg: cfg,
            ctx: ctx,
            started_at: started_at,
            max_wall_clock_sec: max_wall_clock_sec,
            command: runner.command_label,
            command_runner: runner, no_repair: no_repair
          )
          if result.status == :green && runner.settled_head
            Hive::Gh.persist_pr_identity!(
              pr_path,
              pr_url: pr_url,
              pr_number: Hive::Gh.parse_pull_request_url(pr_url).fetch("number"),
              head_oid: runner.settled_head
            )
          end
          return blocked_result(runner.blocked, result) if runner.respond_to?(:blocked) && runner.blocked
          return result unless runner.guardrail_result

          Result.new(
            status: :guardrail,
            attempts: result.attempts,
            last_output: result.last_output,
            error_message: result.error_message,
            limit_text: result.limit_text,
            guardrail: runner.guardrail_result
          )
        rescue JSON::ParserError, Psych::Exception, SystemCallError, IOError => e
          Hive::Stages::Review::CiFix::Result.new(
            status: :error,
            attempts: 0,
            last_output: nil,
            error_message: "GitHub check settlement unavailable: #{e.class}: #{e.message}",
            limit_text: nil
          )
        end

        def blocked_result(blocked, result)
          Result.new(
            status: blocked.reason == "base_conflict" ? :stale : :error,
            attempts: result.attempts,
            last_output: blocked.detail,
            error_message: blocked.detail,
            limit_text: nil,
            reason: blocked.reason
          )
        end

        def skipped_result
          Hive::Stages::Review::CiFix::Result.new(
            status: :skipped,
            attempts: 0,
            last_output: nil,
            error_message: nil,
            limit_text: nil
          )
        end

        class Runner
          attr_reader :guardrail_result, :settled_head, :blocked

          def initialize(task:, cfg:, ctx:, pr_url:, gh: Hive::Gh,
                         publication_base_head: nil, publication_withheld: nil, no_repair: false, admit_head: nil, publication_observer: nil,
                         clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                         sleeper: ->(seconds) { sleep(seconds) },
                         poll_interval_sec: POLL_INTERVAL_SEC,
                         quiet_settlement_sec: QUIET_SETTLEMENT_SEC,
                         no_checks_grace_sec: NO_CHECKS_GRACE_SEC)
            @publication_observer = publication_observer
            @publication_withheld = publication_withheld
            @admit_head = admit_head
            @no_repair = no_repair
            @task = task
            @cfg = cfg
            @ctx = ctx
            @pr_url = pr_url
            @gh = gh
            @clock = clock
            @sleeper = sleeper
            @poll_interval_sec = poll_interval_sec
            @quiet_settlement_sec = quiet_settlement_sec
            @no_checks_grace_sec = no_checks_grace_sec
            @expected_checks = Set.new
            @published_head = publication_base_head.to_s.downcase
            @published_head = nil unless @published_head.match?(/\A[0-9a-f]{40,64}\z/)
            @guardrail_result = nil
            @settled_head = nil
            @blocked = nil
            @required_contexts = {}
          end

          def command_label
            "GitHub checks for the exact pull-request head"
          end

          def call(max_bytes:, timeout_sec:)
            identity = resolve_identity!
            local_head = git_head!
            baseline = @gh.pr_status_rollup(
              @ctx.worktree_path, identity.fetch(:number), cfg: @cfg
            )
            validate_rollup!(baseline, identity)
            remote_head = rollup_head!(baseline)
            unless remote_head == identity.fetch(:remote_head)
              raise Hive::GhError, "pull-request head changed during identity validation"
            end
            @expected_checks.merge(carried_check_keys(baseline))
            guard_publication!(local_head)
            if @no_repair
              raise Hive::GhError, "verification requires the published exact head" unless remote_head == local_head
            else
              publish_head!(identity.fetch(:branch), expected_remote_oid: remote_head)
            end
            @published_head = local_head
            wait_for_settlement!(
              identity,
              local_head,
              max_bytes: max_bytes,
              timeout_sec: timeout_sec
            )
          rescue Hive::GhError, Hive::WorktreeError, SystemCallError, IOError, ArgumentError => e
            Hive::Stages::Review::CiFix::CommandError.new(
              "GitHub check settlement unavailable: #{e.class}: #{e.message}"
            )
          end

          private

          def publication
            @publication ||= Publication.new(task: @task, cfg: @cfg, ctx: @ctx, pr_url: @pr_url, gh: @gh, sleeper: @sleeper)
          end

          def resolve_identity!
            publication.resolve_identity!
          end

          def guard_publication!(local_head)
            raise Hive::GhError, "review publication withheld: #{@publication_withheld}" if @publication_withheld
            return unless @published_head && @published_head != local_head

            guardrail = Hive::Stages::Review::FixGuardrail.run!(
              cfg: @cfg, ctx: @ctx,
              base_sha: @published_head, head_sha: local_head
            )
            @guardrail_result = guardrail if guardrail.status == :tripped
            unless @guardrail_result
              @admit_head&.call(local_head)
              return
            end

            raise Hive::GhError,
                  "CI repair requires fix-guardrail approval before publication"
          end

          def publish_head!(_branch, expected_remote_oid:)
            publication.publish!(expected_head: git_head!)
            @publication_observer&.call(publication)
            evidence = publication.evidence
            unless evidence["publication"] == "published" && evidence["failure_reason"].nil?
              raise Hive::GhError, "review head publication failed: #{evidence['failure_reason']}"
            end
          end

          def wait_for_settlement!(identity, local_head, max_bytes:, timeout_sec:)
            started = @clock.call
            deadline = started + timeout_sec.to_f
            stable_since = nil
            stable_signature = nil
            latest = nil

            loop do
              latest = @gh.pr_status_rollup(
                @ctx.worktree_path, identity.fetch(:number), cfg: @cfg
              )
              validate_rollup!(latest, identity)
              now = @clock.call

              checks_settled = false
              mergeable = latest["mergeable"].to_s.upcase
              if latest["headRefOid"].to_s.downcase == local_head
                return base_conflict(latest, local_head) if mergeable == "CONFLICTING"

                checks = Array(latest["statusCheckRollup"]).select { |entry| entry.is_a?(Hash) }
                keys = check_keys(latest)
                states = checks.to_h { |entry| [ check_key(entry), check_state(entry) ] }
                failures = checks.select { |entry| check_state(entry) == :failed }
                pending = states.value?(:pending) || !@expected_checks.subset?(keys)

                if !pending && failures.any?
                  return failed_run(latest, failures, max_bytes)
                end

                checks_settled = !pending
                # UNKNOWN (GitHub still computing) keeps polling inside the
                # same bounded wait; only a MERGEABLE head may settle green.
                # Required contexts are only consulted once everything else
                # would settle, so the protection lookup stays off the hot path.
                required_gap = nil
                required_gap = required_checks_gap(latest, checks) if checks_settled && mergeable == "MERGEABLE"
                if checks_settled && mergeable == "MERGEABLE" && required_gap.nil?
                  required_quiet = checks.empty? ? @no_checks_grace_sec : @quiet_settlement_sec
                  signature = settlement_signature(checks)
                  if signature != stable_signature
                    stable_signature = signature
                    stable_since = now
                  elsif now - stable_since >= required_quiet
                    @expected_checks.merge(carried_check_keys(latest))
                    @settled_head = local_head
                    return Hive::Stages::Review::CiFix::Run.new(
                      "GitHub checks settled for exact head #{local_head}\n#{behind_note(latest)}", 0
                    )
                  end
                else
                  stable_since = nil
                  stable_signature = nil
                end
              else
                stable_since = nil
                stable_signature = nil
              end

              if now >= deadline
                failures = Array(latest["statusCheckRollup"]).select do |entry|
                  entry.is_a?(Hash) && check_state(entry) == :failed
                end
                if latest["headRefOid"].to_s.downcase == local_head && failures.any?
                  return failed_run(latest, failures, max_bytes)
                end
                return required_checks_blocked(required_gap, latest, local_head, timeout_sec) if required_gap
                return mergeability_unknown(latest, local_head, timeout_sec) if checks_settled

                return Hive::Stages::Review::CiFix::CommandError.new(
                  "GitHub checks did not settle on exact head #{local_head} within #{timeout_sec}s"
                )
              end

              @sleeper.call([ @poll_interval_sec, deadline - now ].min)
            end
          end

          def base_conflict(rollup, local_head)
            base = rollup["baseRefName"].to_s
            base = @ctx.default_branch.to_s if base.empty?
            detail = <<~TEXT
              Pull request #{rollup['url']} conflicts with its base branch `#{base}` at head #{local_head}
              (mergeable=CONFLICTING mergeStateStatus=#{rollup['mergeStateStatus'] || 'unknown'}).
              GitHub does not run the full check suite on a conflicting PR, so CI cannot be treated as green.

              Recovery: in the task worktree, merge the base into the task branch with a merge commit
              (no rebase, no force-push), resolve the conflicts, and commit:

                  git -C #{@ctx.worktree_path} fetch origin
                  git -C #{@ctx.worktree_path} merge --no-ff origin/#{base}

              Then refresh `hive status --operational --json` and invoke this task's
              workflow.retry action so review re-runs on the merged head.
            TEXT
            block!("base_conflict", detail)
          end

          def mergeability_unknown(rollup, local_head, timeout_sec)
            block!(
              "mergeability_unknown",
              "GitHub did not resolve mergeability for #{rollup['url']} at head #{local_head} " \
              "within #{timeout_sec}s (mergeable=#{rollup['mergeable'] || 'missing'}); " \
              "checks settled but review fails closed until GitHub reports MERGEABLE"
            )
          end

          # nil when every required context of the PR's base branch reported a
          # green conclusion on this head (or nothing is required). Otherwise
          # the gap that keeps settlement open: the missing contexts, or the
          # transport error that left the required set unknown. Non-required
          # checks are not consulted here; their failures are handled above.
          def required_checks_gap(rollup, checks)
            base = rollup["baseRefName"].to_s
            base = @ctx.default_branch.to_s if base.empty?
            required = @required_contexts[base] ||= begin
              repository = @gh.parse_pull_request_url(rollup["url"])
              @gh.required_status_check_contexts(
                host: repository.fetch("host"), repository: repository.fetch("repository"),
                branch: base, cfg: @cfg
              )
            end
            green = checks.select { |entry| check_state(entry) == :green }.map { |entry| check_name(entry) }.to_set
            missing = required.reject { |context| green.include?(context) }
            missing.empty? ? nil : { missing: missing, base: base }
          rescue Hive::GhError => e
            { unknown: e.message, base: base }
          end

          def required_checks_blocked(gap, rollup, local_head, timeout_sec)
            if gap[:unknown]
              return block!(
                "required_checks_unknown",
                "GitHub required status checks for base `#{gap[:base]}` of #{rollup['url']} could not be read " \
                "within #{timeout_sec}s (#{gap[:unknown]}); review fails closed until the required set is known"
              )
            end

            block!(
              "required_checks_missing",
              "Required checks for base `#{gap[:base]}` never reported success on #{rollup['url']} at head " \
              "#{local_head} within #{timeout_sec}s: #{gap[:missing].join(', ')}. GitHub may not have created " \
              "them for this head; re-run or re-trigger them, then invoke this task's workflow.retry action"
            )
          end

          def block!(reason, detail)
            @blocked = Blocked.new(reason: reason, detail: detail)
            Hive::Stages::Review::CiFix::CommandError.new(detail)
          end

          # BEHIND is a merge-time branch-protection concern, not a review
          # failure: report it alongside the green result.
          def behind_note(rollup)
            return "" unless rollup["mergeStateStatus"].to_s.upcase == "BEHIND"

            "note: mergeStateStatus=BEHIND; the branch may need a base merge before `gh pr merge`\n"
          end

          def validate_rollup!(rollup, identity)
            unless @gh.parse_pull_request_url(rollup["url"]) ==
                   @gh.parse_pull_request_url(identity.fetch(:url))
              raise Hive::GhError, "GitHub returned a different pull request"
            end
          end

          def rollup_head!(rollup)
            head = rollup["headRefOid"].to_s.downcase
            unless head.match?(/\A[0-9a-f]{40,64}\z/)
              raise Hive::GhError, "GitHub status omitted the pull-request head OID"
            end

            head
          end

          def check_keys(rollup)
            Array(rollup["statusCheckRollup"]).filter_map do |entry|
              check_key(entry) if entry.is_a?(Hash) && !check_name(entry).empty?
            end.to_set
          end

          # Only push-triggered check runs must reappear on a new head. A commit
          # status (StatusContext) names one exact SHA and is posted by whoever
          # checked it, often local tooling after the run (hivedev's bin/ci
          # posts `signoff` for a commit already on the remote). A push never
          # re-triggers it, so carrying it over left the gate pending until the
          # settlement timeout on every review of such a project.
          def carried_check_keys(rollup)
            Array(rollup["statusCheckRollup"]).filter_map do |entry|
              next unless entry.is_a?(Hash) && !check_name(entry).empty?
              next if status_context?(entry)

              check_key(entry)
            end.to_set
          end

          def status_context?(entry)
            entry["__typename"] == "StatusContext" ||
              (entry["__typename"].nil? && entry["name"].to_s.empty? && !entry["context"].to_s.empty?)
          end

          def check_key(entry)
            [ entry["workflowName"].to_s, check_name(entry) ].join("\0")
          end

          def check_name(entry)
            name = entry["name"].to_s
            name.empty? ? entry["context"].to_s : name
          end

          def check_state(entry)
            conclusion = entry["conclusion"].to_s.upcase
            status = entry["status"].to_s.upcase
            state = entry["state"].to_s.upcase
            return :failed if FAILURE_CONCLUSIONS.include?(conclusion) || state == "FAILURE"
            return :green if GREEN_CONCLUSIONS.include?(conclusion) || state == "SUCCESS"
            return :pending if conclusion.empty? || PENDING_STATUSES.include?(status) ||
                               PENDING_STATES.include?(state)

            :failed
          end

          def settlement_signature(checks)
            JSON.generate(
              checks.map do |entry|
                [ check_key(entry), entry["status"], entry["state"], entry["conclusion"] ]
              end.sort
            )
          end

          def failed_run(rollup, failures, max_bytes)
            jobs = @gh.failing_jobs_with_logs(
              @ctx.worktree_path, rollup, cfg: @cfg, byte_cap: max_bytes
            )
            body = if jobs.empty?
              failures.map do |entry|
                url = entry["detailsUrl"].to_s
                url = entry["targetUrl"].to_s if url.empty?
                "#{check_name(entry)}: " \
                  "#{entry['conclusion'].to_s.empty? ? entry['state'] : entry['conclusion']} #{url}"
              end.join("\n")
            else
              jobs.map do |job|
                "## #{job['name']}\n#{job['log']}"
              end.join("\n\n")
            end
            body = "GitHub checks failed without diagnostics" if body.empty?
            body = body.byteslice(-max_bytes, max_bytes) if body.bytesize > max_bytes
            Hive::Stages::Review::CiFix::Run.new(body, 1)
          end

          def git_head!
            out, err, status = Open3.capture3(
              "git", "-C", @ctx.worktree_path, "rev-parse", "--verify", "HEAD"
            )
            head = out.to_s.strip.downcase
            unless status.success? && head.match?(/\A[0-9a-f]{40,64}\z/)
              detail = err.to_s.strip
              raise Hive::GhError, "review worktree HEAD is unavailable#{": #{detail}" unless detail.empty?}"
            end

            head
          end
        end
      end
    end
  end
end
