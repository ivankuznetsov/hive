require "time"
require "set"
require "hive/config"
require "hive/gh"
require "hive/git_ops"
require "hive/markers"
require "hive/task"
require "hive/task_closure"
require "hive/task_projection/reader"
require "hive/task_resolver"
require "hive/workflows"
require "hive/task_activity"

module Hive
  module Daemon
    # Tasks and GitHub are authority. Poll cadence is process-local; restart
    # rediscovers tasks and repeats idempotent intake and closure operations.
    class PrMergeWatcher
      SUPPORTED_STAGES = %w[open-pr review artifacts finalize].map do |verb|
        Hive::Workflows::VERBS.fetch(verb).fetch(:target)
      end.freeze
      DEFAULT_POLL_TIMEOUT_SEC = Hive::Gh::NETWORK_TIMEOUT_SEC

      def initialize(poll_interval_sec: 300, merge_intake: nil,
                     poll_timeout_sec: DEFAULT_POLL_TIMEOUT_SEC,
                     gh: Hive::Gh, config_lookup: Hive::Config.method(:find_project),
                     config_loader: Hive::Config.method(:load),
                     task_factory: Hive::Task.method(:new),
                     task_closure: Hive::TaskClosure, dry_run: false)
        @poll_interval_sec = positive_number(poll_interval_sec, "poll interval", allow_zero: true)
        @poll_timeout_sec = positive_number(poll_timeout_sec, "poll timeout")
        @merge_intake = merge_intake
        @candidates = {}
        @polls = {}
        @gh = gh
        @config_lookup = config_lookup
        @config_loader = config_loader
        @task_factory = task_factory
        @task_closure = task_closure
        @dry_run = dry_run
        @contexts = {}
        @last_observation_results = []
      end

      attr_reader :last_observation_results

      def observe(rows, now: Time.now.utc, projects: nil)
        @last_observation_results = []
        grouped = Array(rows).group_by { |row| row.project.to_s }
        @contexts = {}
        @candidates = {}
        (Array(projects).map(&:to_s) + grouped.keys).uniq.sort.each do |project|
          project_rows = grouped.fetch(project, []).select { |row| tracked_row?(row) }
          # Unreadable candidates still fence error recovery.
          project_rows.each { |row| @candidates[[ project, row.slug.to_s ]] = nil }
          identity = identity_for(project)
          unless identity
            project_rows.each { |row| @candidates.delete([ project, row.slug.to_s ]) }
            @last_observation_results << {
              status: :skipped, project: project,
              reason: "project has no GitHub repository identity; merge reconciliation is not applicable"
            }
            next
          end
          @contexts[project] = identity
          project_rows.each do |row|
            key = [ project, row.slug.to_s ]
            candidate = candidate_for(row, identity)
            candidate ? @candidates[key] = candidate : @candidates.delete(key)
          rescue StandardError => e
            @last_observation_results << {
              status: :blocked, project: project, slug: row.slug.to_s, reason: bounded_error(e)
            }
          end
          @last_observation_results << {
            status: :observed, project: project, candidates: project_rows.length
          }
        rescue StandardError => e
          @last_observation_results << { status: :blocked, project: project, reason: bounded_error(e) }
        end
        active_keys = @candidates.values.compact.to_set { |candidate| candidate.fetch("key") }
        @polls.select! { |key, _| active_keys.include?(key) }
        @last_observation_results
      end

      # Oldest-polled eligible task first: held and failing tasks cannot starve
      # siblings. One task per project per tick bounds GitHub work.
      def tick(now: Time.now.utc, projects: nil)
        selected = projects ? @contexts.keys & Array(projects).map(&:to_s) : @contexts.keys
        by_project = @candidates.values.compact.group_by { |item| item.dig("task", "project") }
        selected.sort.filter_map do |project|
          candidates = by_project.fetch(project, []).select do |item|
            item.dig("observation", "held") != true &&
              (!@polls[item["key"]] || @polls[item["key"]][:at] + @poll_interval_sec <= now)
          end
          candidate = candidates.min_by do |item|
            [ @polls.dig(item["key"], :at) || Time.at(0), item.dig("task", "slug") ]
          end
          next unless candidate

          result = process_candidate(@contexts.fetch(project), candidate, now: now)
          @polls[candidate["key"]] = { at: now, state: result.dig(:remote, "state") }
          result.merge(project: project, slug: candidate.dig("task", "slug"))
        end
      end

      def recovery_blocked?(project:, slug:)
        key = [ project.to_s, slug.to_s ]
        return false unless @candidates.key?(key)

        candidate = @candidates[key]
        return true unless candidate && candidate.dig("observation", "held") != true

        !%w[open closed_unmerged].include?(@polls.dig(candidate["key"], :state))
      end

      def state_for(project:, slug:)
        candidate = @candidates[[ project.to_s, slug.to_s ]]
        candidate && @polls.dig(candidate["key"], :state)&.upcase
      end

      private

      def candidate_for(row, identity)
        task = @task_factory.call(row.folder)
        pr_path = File.join(task.folder, "pr.md")
        begin
          File.lstat(pr_path)
        rescue Errno::ENOENT
          return nil if row.stage.to_s == Hive::Workflows::VERBS.fetch("open-pr").fetch(:target)

          raise
        end
        # Before publication this stage's state file contains only its marker,
        # not PR metadata. Its publication controller owns normal recovery.
        if row.stage.to_s == Hive::Workflows::VERBS.fetch("open-pr").fetch(:target) &&
           !File.read(pr_path).start_with?("---")
          return nil
        end
        marker = Hive::Markers.current(task.state_file)
        task_generation = Hive::TaskClosure.task_generation(
          task, marker: marker,
          condition_task_generation: row.condition_task_generation,
          commit_generation: row.commit_generation
        )
        frontmatter = Hive::Gh.pr_frontmatter(pr_path)
        pull_request = parse_pr_url(frontmatter["pr_url"].to_s)
        raise Hive::Error, "task pull request URL is not a canonical GitHub pull request" unless pull_request

        observed_head = observed_head_for(task, identity, frontmatter)
        repository_mismatch =
          pull_request.fetch("host") != identity.fetch("host") ||
          pull_request.fetch("repository") != identity.fetch("repository")
        pull_request = pull_request.merge("observed_head" => observed_head)
        key = [
          row.project.to_s, row.slug.to_s, task_generation,
          Hive::TaskClosure.marker_generation(marker), pull_request
        ]
        {
          "key" => key,
          "task" => { "project" => row.project.to_s, "slug" => row.slug.to_s },
          "observation" => {
            "marker_generation" => Hive::TaskClosure.marker_generation(marker),
            "task_generation" => task_generation,
            "held" => held_row?(row) || repository_mismatch
          },
          "pull_request" => pull_request
        }
      end

      def process_candidate(identity, candidate, now:)
        task = resolve_candidate_task(candidate)
        return terminal_result(task, identity, now: now) if Hive::TaskClosure.terminal_task?(task)
        generation = generation_status(task, candidate)
        unless generation.fetch(:status) == :current
          return { status: :blocked, reason: generation[:reason] || "task generation changed before reconciliation" }
        end
        frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))
        unless parse_pr_url(frontmatter["pr_url"].to_s) == candidate.fetch("pull_request").except("observed_head")
          raise Hive::ConcurrentRunError, "task pull request binding changed before reconciliation"
        end
        result = remote_result(poll_facts(identity, candidate), candidate, now: now)
        record_remote_activity(task, candidate, result, now: now)
        return result unless result.fetch(:status) == :merged

        unless Hive::TaskClosure.local_pr_head_binding(task, frontmatter: frontmatter) ==
               candidate.dig("pull_request", "observed_head")
          raise Hive::ConcurrentRunError, "task pull request head changed before archival"
        end
        remote = result.fetch(:remote)
        intake = ensure_architecture_intake(identity, candidate, now: now)
        return intake.merge(remote: remote) unless intake.fetch(:status) == :ready
        return { status: :dry_run, remote: remote } if @dry_run

        receipt = @task_closure.reconcile_remote_merge!(
          task: task,
          project: identity.fetch("registration"),
          pr_url: candidate.dig("pull_request", "url"),
          expected_head: candidate.dig("pull_request", "observed_head"),
          expected_merge_oid: remote.fetch("merge_oid"),
          gh: @gh,
          now: now
        )
        { status: :archived, remote: remote, receipt_digest: receipt.fetch("receipt_digest") }
      rescue Hive::TaskClosure::VerificationFailed,
             Hive::TaskClosure::InvalidReceipt,
             Hive::ConcurrentRunError => e
        { status: :blocked, reason: bounded_error(e) }
      rescue StandardError => e
        { status: :failed, reason: bounded_error(e) }
      end

      def poll_facts(identity, candidate)
        cfg = @config_loader.call(identity.fetch("project_path"))
        @gh.closure_pr_facts(
          host: identity.fetch("host"),
          repository: identity.fetch("repository"),
          number: candidate.dig("pull_request", "number"),
          default_branch: identity.fetch("default_branch"),
          cfg: cfg,
          timeout_sec: @poll_timeout_sec
        )
      end

      def record_remote_activity(task, candidate, result, now:)
        remote = result[:remote]
        return false unless remote

        # TaskActivity deduplicates observations by operation ID across polls and restarts.
        activity = Hive::TaskActivity.for_task(task, clock: -> { now.utc })
        return false unless activity

        number = candidate.dig("pull_request", "number")
        state = remote.fetch("state")
        kind = state == "merged" ? "merge_observed" : "pr_observed"
        activity.record(
          kind: kind,
          operation_id: "github:pr:#{number}:#{state}:#{remote['merge_oid'] || 'none'}",
          correlation_id: "publication:#{number}",
          reason: "pull request outcome changed", source: "github",
          occurred_at: remote["merged_at"] || now, observed_at: now,
          payload: {
            "pr_number" => number,
            "pr_url" => candidate.dig("pull_request", "url"),
            "pr_state" => state,
            "head_oid" => candidate.dig("pull_request", "observed_head"),
            "merge_oid" => remote["merge_oid"],
            "merged_at" => remote["merged_at"],
            "draft" => false
          }
        )
        true
      rescue Hive::TaskActivity::Error, SystemCallError, IOError
        false
      end

      def remote_result(facts, candidate, now:)
        state = facts.fetch("state").to_s.upcase
        raise Hive::GhError, "unknown pull request state #{state.inspect}" unless %w[OPEN CLOSED MERGED].include?(state)
        remote = {
          "state" => case state
                     when "OPEN" then "open"
                     when "MERGED" then "merged"
                     else "closed_unmerged"
                     end,
          "merge_oid" => blank_to_nil(facts["merge_oid"]&.downcase),
          "merged_at" => timestamp_for(facts["merged_at"]),
          "observed_at" => now.utc.iso8601(6)
        }
        if state == "MERGED"
          expected_head = candidate.dig("pull_request", "observed_head")
          observed_head = facts["head_oid"].to_s.downcase
          unless expected_head
            remote["state"] = "ambiguous"
            return {
              status: :blocked,
              remote: remote,
              archive: {
                "status" => "blocked",
                "last_error" => "task has no immutable local PR head binding"
              },
              next_poll_at: now + @poll_interval_sec
            }
          end
          if observed_head != expected_head
            remote["state"] = "delivered_elsewhere"
            return {
              status: :blocked,
              remote: remote,
              archive: {
                "status" => "blocked",
                "last_error" => "merged pull request head changed after task observation"
              },
              next_poll_at: now + @poll_interval_sec
            }
          end
          unless remote["merge_oid"]&.match?(/\A[a-f0-9]{40,64}\z/) &&
                 facts["reachable_from_default"] == true
            raise Hive::GhError,
                  "merged pull request lacks reachable immutable merge evidence"
          end
          return { status: :merged, remote: remote }
        end

        {
          status: state == "OPEN" ? :open : :closed_unmerged,
          remote: remote,
          next_poll_at: now + @poll_interval_sec
        }
      end

      def ensure_architecture_intake(identity, candidate, now:)
        receipt = @merge_intake&.ingest(
          project: identity.fetch("registration"), pr: candidate.dig("pull_request", "url"), now: now
        )
        return { status: :deferred } if receipt == :deferred

        classification = receipt.is_a?(Hash) && receipt.dig("classification", "status")
        case classification
        when "blocked"
          { status: :blocked, reason: "post-merge classification is blocked" }
        when "pending", "retry_wait", "would_classify"
          { status: :deferred, reason: "post-merge classification is #{classification}" }
        else
          { status: :ready }
        end
      rescue StandardError => e
        { status: :deferred, reason: bounded_error(e) }
      end

      def terminal_result(task, identity, now:)
        closure = Hive::TaskClosure.read(task, project: identity.fetch("registration"))
        if closure.valid?
          { status: :already_archived, receipt_digest: closure.receipt.fetch("receipt_digest") }
        else
          { status: :blocked, reason: "terminal task has no valid merge closure receipt" }
        end
      end

      def generation_status(task, candidate)
        marker = Hive::Markers.current(task.state_file)
        bounded = Hive::TaskProjection::Reader.new(
          task_folder: task.folder, task: task
        ).read_routine(marker: marker)
        unless bounded.current?
          reason = bounded.diagnostics.first&.fetch("reason", nil) || bounded.state
          return {
            status: :unavailable,
            reason: "task journal is invalid (#{reason})"
          }
        end

        current = Hive::TaskClosure.task_generation(
          task, marker: marker, projection: bounded.projection
        ) ==
          candidate.dig("observation", "task_generation") &&
          Hive::TaskClosure.marker_generation(marker) ==
            candidate.dig("observation", "marker_generation")
        { status: current ? :current : :changed }
      end

      def resolve_candidate_task(candidate)
        Hive::TaskResolver.new(
          candidate.dig("task", "slug"),
          project_filter: candidate.dig("task", "project")
        ).resolve
      end

      def identity_for(project)
        registration = @config_lookup.call(project.to_s)
        raise Hive::ConfigError, "unknown registered project #{project.inspect}" unless registration

        project_path = registration.fetch("path")
        hive_state_path = registration.fetch("hive_state_path")
        stored = registration.fetch("repository_identity", "").to_s.downcase
        return nil if stored.empty? || stored.start_with?("local:")

        cfg = @config_loader.call(project_path)
        live = @gh.repository_identity(project_path, cfg: cfg)
        host = live.fetch("host").downcase
        repository = live.fetch("repository").downcase
        expected = "#{host}/#{repository}"
        unless stored == expected
          raise Hive::ConfigError,
                "registered repository identity must exactly match #{expected}"
        end
        branch = cfg["default_branch"].to_s
        branch = @gh.closure_default_branch(
          host: host, repository: repository, cfg: cfg
        ) if branch.empty?
        {
          "registration" => project.to_s,
          "project_path" => File.expand_path(project_path),
          "hive_state_path" => File.expand_path(hive_state_path),
          "host" => host,
          "repository" => repository,
          "default_branch" => branch
        }
      end

      def tracked_row?(row)
        SUPPORTED_STAGES.include?(row.stage.to_s) &&
          row.workflow.to_s == "coding" &&
          !Hive::TaskProjection.history_invalid_row?(row)
      end

      def held_row?(row)
        row.blocked == true || !row.admission_error.nil?
      end

      def parse_pr_url(value)
        Hive::Gh.parse_pull_request_url(value)
      end

      def observed_head_for(task, identity, frontmatter)
        # Controller metadata is the binding; owned worktree is legacy fallback.
        head = %w[head_oid head_sha headRefOid].filter_map do |field|
          value = frontmatter[field].to_s.downcase
          value if value.match?(/\A[a-f0-9]{40,64}\z/)
        end.first
        return head if head

        Hive::TaskClosure.local_pr_head_binding(
          task,
          frontmatter: frontmatter,
          project_root: identity.fetch("project_path")
        )
      end

      def timestamp_for(value)
        return nil if value.nil? || value.to_s.empty?

        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError
        nil
      end

      def blank_to_nil(value)
        value.to_s.empty? ? nil : value
      end

      def bounded_error(error)
        "#{error.class}: #{error.message}"[0, 500]
      end

      def positive_number(value, label, allow_zero: false)
        number = Float(value)
        valid = number.finite? && (allow_zero ? number >= 0 : number.positive?)
        raise ArgumentError unless valid

        number
      rescue ArgumentError, TypeError
        qualifier = allow_zero ? "non-negative" : "positive"
        raise ArgumentError, "PR merge watcher #{label} must be #{qualifier}"
      end
    end
  end
end
