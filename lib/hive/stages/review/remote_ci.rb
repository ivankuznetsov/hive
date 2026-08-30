require "json"
require "open3"
require "set"
require "yaml"
require "hive/gh"
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
        Result = Data.define(
          :status, :attempts, :last_output, :error_message, :limit_text,
          :guardrail
        )
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
                 publication_base_head: nil, runner: nil)
          return skipped_result if cfg.dig("review", "github_checks", "enabled") == false

          pr_path = File.join(task.folder, "pr.md")
          return skipped_result unless File.file?(pr_path)

          pr_url = Hive::Gh.pr_frontmatter(pr_path)["pr_url"].to_s
          return skipped_result if pr_url.empty?

          runner ||= Runner.new(
            task: task, cfg: cfg, ctx: ctx, pr_url: pr_url,
            publication_base_head: publication_base_head
          )
          result = Hive::Stages::Review::CiFix.run!(
            cfg: cfg,
            ctx: ctx,
            started_at: started_at,
            max_wall_clock_sec: max_wall_clock_sec,
            command: runner.command_label,
            command_runner: runner
          )
          if result.status == :green && runner.settled_head
            Hive::Gh.persist_pr_identity!(
              pr_path,
              pr_url: pr_url,
              pr_number: Hive::Gh.parse_pull_request_url(pr_url).fetch("number"),
              head_oid: runner.settled_head
            )
          end
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
          attr_reader :guardrail_result, :settled_head

          def initialize(task:, cfg:, ctx:, pr_url:, gh: Hive::Gh,
                         publication_base_head: nil,
                         clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                         sleeper: ->(seconds) { sleep(seconds) },
                         poll_interval_sec: POLL_INTERVAL_SEC,
                         quiet_settlement_sec: QUIET_SETTLEMENT_SEC,
                         no_checks_grace_sec: NO_CHECKS_GRACE_SEC)
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
            @expected_checks.merge(check_keys(baseline))
            guard_publication!(local_head)
            publish_head!(identity.fetch(:branch), expected_remote_oid: remote_head)
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

          def resolve_identity!
            parsed = @gh.parse_pull_request_url(@pr_url)
            raise Hive::GhError, "pr.md contains an invalid pull-request URL" unless parsed

            root = Hive::Worktree.canonical_root(@task.project_root)
            pointer = Hive::Worktree.read_owned_pointer(
              @task.folder,
              project_root: @task.project_root,
              slug: @task.slug,
              expected_root: root
            )
            unless File.realpath(pointer.fetch("path")) == File.realpath(@ctx.worktree_path)
              raise Hive::WorktreeError, "review context does not match the owned worktree"
            end

            repository = @gh.repository_identity(@ctx.worktree_path, cfg: @cfg)
            unless parsed.fetch("host") == repository.fetch("host").downcase &&
                   parsed.fetch("repository") == repository.fetch("repository").downcase
              raise Hive::GhError, "pull request is outside the task repository"
            end

            metadata = @gh.pr_metadata(
              parsed.fetch("number"), cfg: @cfg, chdir: @ctx.worktree_path
            )
            unless metadata.number == parsed.fetch("number") &&
                   @gh.parse_pull_request_url(metadata.url) == parsed &&
                   metadata.state.to_s.upcase == "OPEN" &&
                   metadata.is_cross_repository == false
              raise Hive::GhError, "pull-request identity is stale or unsupported"
            end

            branch = pointer.fetch("branch")
            matches = @gh.lookup_prs_for_branch(
              @ctx.worktree_path, branch, cfg: @cfg
            ).select do |candidate|
              candidate["number"].to_i == parsed.fetch("number") &&
                candidate["state"].to_s.upcase == "OPEN" &&
                candidate["headRefName"].to_s == branch &&
                @gh.parse_pull_request_url(candidate["url"]) == parsed
            end
            raise Hive::GhError, "task branch does not resolve to one open pull request" unless matches.one?

            remote_head = metadata.head_ref_oid.to_s.downcase
            unless remote_head.match?(/\A[0-9a-f]{40,64}\z/)
              raise Hive::GhError, "pull-request head OID is unavailable"
            end

            {
              number: parsed.fetch("number"), url: parsed.fetch("url"),
              branch: branch, remote_head: remote_head
            }
          end

          def guard_publication!(local_head)
            return unless @published_head && @published_head != local_head

            guardrail = Hive::Stages::Review::FixGuardrail.run!(
              cfg: @cfg, ctx: @ctx,
              base_sha: @published_head, head_sha: local_head
            )
            @guardrail_result = guardrail if guardrail.status == :tripped
            return unless @guardrail_result

            raise Hive::GhError,
                  "CI repair requires fix-guardrail approval before publication"
          end

          def publish_head!(branch, expected_remote_oid:)
            result = @gh.push_branch(
              @ctx.worktree_path, branch, cfg: @cfg,
              expected_remote_oid: expected_remote_oid,
              set_upstream: false
            )
            return if result.success?

            detail = result.stderr.to_s.strip
            detail = result.stdout.to_s.strip if detail.empty?
            raise Hive::GhError, "review head publication failed#{": #{detail}" unless detail.empty?}"
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

              if latest["headRefOid"].to_s.downcase == local_head
                checks = Array(latest["statusCheckRollup"]).select { |entry| entry.is_a?(Hash) }
                keys = check_keys(latest)
                states = checks.to_h { |entry| [ check_key(entry), check_state(entry) ] }
                failures = checks.select { |entry| check_state(entry) == :failed }
                pending = states.value?(:pending) || !@expected_checks.subset?(keys)

                if !pending && failures.any?
                  return failed_run(latest, failures, max_bytes)
                end

                if !pending && failures.empty?
                  required_quiet = checks.empty? ? @no_checks_grace_sec : @quiet_settlement_sec
                  signature = settlement_signature(checks)
                  if signature != stable_signature
                    stable_signature = signature
                    stable_since = now
                  elsif now - stable_since >= required_quiet
                    @expected_checks.merge(keys)
                    @settled_head = local_head
                    return Hive::Stages::Review::CiFix::Run.new(
                      "GitHub checks settled for exact head #{local_head}\n", 0
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

                return Hive::Stages::Review::CiFix::CommandError.new(
                  "GitHub checks did not settle on exact head #{local_head} within #{timeout_sec}s"
                )
              end

              @sleeper.call([ @poll_interval_sec, deadline - now ].min)
            end
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
