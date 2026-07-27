require "digest"
require "json"
require "time"
require "uri"
require "hive/config"
require "hive/daemon/pr_merge_reconciliation_store"
require "hive/gh"
require "hive/git_ops"
require "hive/markers"
require "hive/task"
require "hive/task_closure"
require "hive/task_resolver"
require "hive/workflows"

module Hive
  module Daemon
    # Durable task-bound pull-request reconciliation.
    #
    # Every PR-bearing coding stage is observed, not only a clean completed
    # finalize. Remote state, architecture intake, retry/backoff, and archive
    # receipt live in PrMergeReconciliationStore, so daemon restart and a
    # transient GitHub or intake failure cannot silently forget a task.
    class PrMergeWatcher
      SUPPORTED_STAGES = %w[open-pr review artifacts finalize].map do |verb|
        Hive::Workflows::VERBS.fetch(verb).fetch(:target)
      end.freeze
      DEFAULT_POLL_TIMEOUT_SEC = Hive::Gh::NETWORK_TIMEOUT_SEC

      def initialize(poll_interval_sec: 300, merge_intake: nil,
                     poll_timeout_sec: DEFAULT_POLL_TIMEOUT_SEC,
                     store: PrMergeReconciliationStore.new,
                     gh: Hive::Gh, config_lookup: Hive::Config.method(:find_project),
                     config_loader: Hive::Config.method(:load),
                     task_factory: Hive::Task.method(:new),
                     task_closure: Hive::TaskClosure, dry_run: false)
        @poll_interval_sec = positive_number(poll_interval_sec, "poll interval", allow_zero: true)
        @poll_timeout_sec = positive_number(poll_timeout_sec, "poll timeout")
        @merge_intake = merge_intake
        @store = store
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

      # Refresh the durable backlog from one complete hive-status graph.
      # Project failures are isolated: a bad identity/store blocks that
      # project while healthy registrations continue.
      def observe(rows, now: Time.now.utc, projects: nil)
        @last_observation_results = []
        rows_by_project = Array(rows).group_by { |row| row.project.to_s }
        observed_projects = (
          Array(projects).map(&:to_s) + rows_by_project.keys.map(&:to_s)
        ).uniq.sort
        observed_projects.each do |project|
          project_rows = rows_by_project.fetch(project, [])
          begin
            identity = identity_for(project)
            unless identity
              @contexts.delete(project.to_s)
              @last_observation_results << {
                status: :skipped, project: project.to_s,
                reason: "project has no GitHub repository identity; " \
                        "merge reconciliation is not applicable"
              }
              next
            end
            @contexts[project.to_s] = identity
            issues = []
            outcomes = []
            active = project_rows.filter_map do |row|
              next unless tracked_row?(row)

              candidate, issue, outcome = candidate_for(row, identity, now: now)
              issues << issue if issue
              outcomes << outcome
              candidate
            end
            sync_candidates(
              identity, active, project_rows, outcomes: outcomes, now: now
            )
            @last_observation_results << {
              status: :observed, project: project.to_s, candidates: active.length
            }
            issues.each do |issue|
              @last_observation_results << {
                status: :blocked, project: project.to_s, **issue
              }
            end
          rescue StandardError => e
            @last_observation_results << {
              status: :blocked, project: project.to_s,
              reason: bounded_error(e)
            }
          end
        end
        @last_observation_results
      end

      # One fair candidate per observed project per tick. Each project has an
      # independently persisted cursor and backoff, so one repository cannot
      # consume every opportunity or permanently evict another task.
      def tick(now: Time.now.utc, projects: nil)
        selected = projects ? @contexts.keys & Array(projects).map(&:to_s) : @contexts.keys
        selected.sort.filter_map do |project|
          identity = @contexts.fetch(project)
          state = @store.load(identity)
          next unless state

          candidate = @store.next_candidate(state, now: now)
          next unless candidate

          process_and_record(identity, candidate, now: now)
        rescue StandardError => e
          {
            status: :blocked, project: project,
            slug: candidate&.dig("task", "slug"),
            reason: bounded_error(e)
          }
        end
      end

      def pending_count
        each_candidate.count do |candidate|
          !%w[archived superseded].include?(candidate.dig("archive", "status"))
        end
      end

      def watching?(project:, slug:)
        candidates_for(project).any? do |candidate|
          candidate.dig("task", "slug") == slug.to_s &&
            !%w[archived superseded].include?(candidate.dig("archive", "status"))
        end
      end

      # Error recovery must wait until the durable watcher has classified the
      # task-bound PR. Unknown/merged/ambiguous candidates stay fenced; a
      # confirmed open or closed-unmerged PR may continue through ordinary
      # recovery because delivery has not happened.
      def recovery_blocked?(project:, slug:)
        candidate = candidates_for(project).reverse.find do |item|
          item.dig("task", "slug") == slug.to_s &&
            !%w[archived superseded].include?(item.dig("archive", "status"))
        end
        return false unless candidate

        !%w[open closed_unmerged].include?(candidate.dig("remote", "state"))
      end

      def state_for(project:, slug:)
        candidate = candidates_for(project).reverse.find do |item|
          item.dig("task", "slug") == slug.to_s
        end
        candidate&.dig("remote", "state")&.upcase
      end

      private

      def sync_candidates(identity, observed, rows, outcomes:, now:)
        observed_by_key = observed.to_h { |candidate| [ candidate.fetch("key"), candidate ] }
        terminal_slugs = Array(rows).select { |row| terminal_row?(row) }.to_h do |row|
          [ row.slug.to_s, true ]
        end
        @store.transaction(identity, now: now) do |state|
          candidates = state.fetch("candidates")
          candidates_by_task = candidates.values.group_by do |candidate|
            [ candidate.dig("task", "project"), candidate.dig("task", "slug") ]
          end
          observed.each do |candidate|
            key = candidate.fetch("key")
            task_key = [
              candidate.dig("task", "project"),
              candidate.dig("task", "slug")
            ]
            task_candidates = candidates_by_task.fetch(task_key, [])
            same_generation = task_candidates.find do |existing|
              existing.dig("observation", "task_generation") ==
                  candidate.dig("observation", "task_generation") &&
                existing.fetch("key") != key &&
                existing.dig("archive", "status") != "archived"
            end
            if same_generation && binding_drift?(same_generation, candidate)
              candidate["observation"]["held"] = true
              candidate["observation"]["hold_reason"] =
                binding_drift_reason(same_generation, candidate)
            end
            task_candidates.each do |existing|
              next if existing.fetch("key") == key
              next if existing.dig("archive", "status") == "archived"

              existing["archive"]["status"] = "superseded"
              existing["archive"]["last_error"] =
                if existing.dig("observation", "task_generation") ==
                   candidate.dig("observation", "task_generation")
                  "pull request binding changed within one task generation"
                else
                  "a newer task generation was observed"
                end
              existing["updated_at"] = now.utc.iso8601(6)
            end
            candidates[key] = merge_observation(candidates[key], candidate)
            task_candidates.reject! { |existing| existing.fetch("key") == key }
            task_candidates << candidates.fetch(key)
            candidates_by_task[task_key] = task_candidates
          end
          candidates.each_value do |candidate|
            next unless terminal_slugs.key?(candidate.dig("task", "slug"))
            next if observed_by_key.key?(candidate.fetch("key"))

            mark_terminal_candidate(candidate, identity, now: now)
          end
          state["backlog"] = {
            "watermark" => state.dig("backlog", "watermark") || now.utc.iso8601(6),
            "scanned_at" => now.utc.iso8601(6),
            "complete" => true,
            "outcomes" => outcomes.to_h { |outcome| [ outcome.fetch("key"), outcome ] }
          }
        end
      end

      def candidate_for(row, identity, now:)
        task = @task_factory.call(row.folder)
        marker = Hive::Markers.current(task.state_file)
        task_generation = Hive::TaskClosure.task_generation(task, marker: marker)
        pull_request = parse_pr_url(row.pr_url.to_s.empty? ? read_pr_url(task) : row.pr_url)
        unless pull_request
          issue = {
          slug: row.slug.to_s,
          reason: "task pull request URL is not a canonical GitHub pull request"
          }
          return [
            nil,
            issue,
            backlog_outcome(
              row, task_generation,
              status: "rejected", reason: issue.fetch(:reason),
              candidate_key: nil, now: now
            )
          ]
        end

        timestamp = now.utc.iso8601(6)
        frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))
        observed_head = observed_head_for(task, identity, frontmatter)
        repository_mismatch =
          pull_request.fetch("host") != identity.fetch("host") ||
          pull_request.fetch("repository") != identity.fetch("repository")
        candidate_hold_reason = if repository_mismatch
          "pull_request_repository_mismatch"
        else
          hold_reason(row)
        end
        pull_request = pull_request.merge("observed_head" => observed_head)
        key = @store.candidate_key(
          project: row.project,
          slug: row.slug,
          task_generation: task_generation,
          pull_request: pull_request
        )
        candidate = {
          "key" => key,
          "task" => {
            "project" => row.project.to_s,
            "slug" => row.slug.to_s,
            "id" => row.id,
            "workflow" => row.workflow.to_s,
            "folder" => task.folder
          },
          "observation" => {
            "stage" => stage_dir(task),
            "marker" => marker.name.to_s,
            "marker_generation" => Hive::TaskClosure.marker_generation(marker),
            "task_generation" => task_generation,
            "state_file_mtime" => timestamp_for(row.state_file_mtime),
            "held" => held_row?(row) || repository_mismatch,
            "hold_reason" => candidate_hold_reason
          },
          "pull_request" => pull_request,
          "remote" => {
            "state" => "unknown", "merge_oid" => nil,
            "merged_at" => nil, "observed_at" => nil
          },
          "architecture" => {
            "status" => "pending", "request_id" => nil,
            "receipt" => nil, "last_error" => nil
          },
          "archive" => {
            "status" => "pending", "receipt_digest" => nil,
            "archived_at" => nil, "last_error" => nil
          },
          "retry" => { "failures" => 0, "not_before" => nil },
          "updated_at" => timestamp
        }
        [
          candidate,
          nil,
          backlog_outcome(
            row, task_generation,
            status: "candidate", reason: candidate_hold_reason,
            candidate_key: key, now: now
          )
        ]
      end

      def process_and_record(identity, candidate, now:)
        result = process_candidate(identity, candidate, now: now)
        @store.transaction(identity, now: now) do |state|
          current = state.fetch("candidates")[candidate.fetch("key")]
          next unless current
          next unless current.dig("observation", "task_generation") ==
            candidate.dig("observation", "task_generation")

          apply_result!(current, result, now: now)
          @store.advance_cursor!(state, current.fetch("key"))
        end
        result.merge(
          project: identity.fetch("registration"),
          slug: candidate.dig("task", "slug")
        )
      rescue StandardError => e
        @store.transaction(identity, now: now) do |state|
          current = state.fetch("candidates")[candidate.fetch("key")]
          if current
            message = @store.record_failure!(current, e, now: now)
            current["archive"]["status"] = "failed"
            current["archive"]["last_error"] = message
            @store.advance_cursor!(state, current.fetch("key"))
          end
        end
        {
          status: :failed,
          project: identity.fetch("registration"),
          slug: candidate.dig("task", "slug"),
          reason: bounded_error(e)
        }
      end

      def process_candidate(identity, candidate, now:)
        task = resolve_candidate_task(candidate)
        return terminal_result(task, identity, now: now) if Hive::TaskClosure.terminal_task?(task)
        unless generation_current?(task, candidate)
          return {
            status: :superseded,
            archive: { "status" => "superseded",
                       "last_error" => "task generation changed before reconciliation" }
          }
        end

        remote = candidate.fetch("remote")
        unless remote["state"] == "merged"
          facts = poll_facts(identity, candidate)
          remote_result = remote_result(facts, candidate, now: now)
          checkpoint!(identity, candidate, remote_result, now: now)
          return remote_result unless remote_result.fetch(:status) == :merged

          remote = remote_result.fetch(:remote)
        end

        architecture = ensure_architecture_intake(
          identity, candidate, remote, now: now
        )
        checkpoint!(identity, candidate, architecture, now: now)
        return architecture if architecture.fetch(:status) == :deferred
        if @dry_run
          return {
            status: :dry_run,
            remote: remote,
            architecture: architecture.fetch(:architecture),
            archive: candidate.fetch("archive"),
            next_poll_at: now + @poll_interval_sec
          }
        end

        receipt = @task_closure.reconcile_remote_merge!(
          task: task,
          project: identity.fetch("registration"),
          pr_url: candidate.dig("pull_request", "url"),
          expected_head: candidate.dig("pull_request", "observed_head"),
          expected_merge_oid: remote.fetch("merge_oid"),
          gh: @gh,
          now: now
        )
        {
          status: :archived,
          remote: remote,
          architecture: architecture.fetch(:architecture),
          archive: {
            "status" => "archived",
            "receipt_digest" => receipt.fetch("receipt_digest"),
            "archived_at" => now.utc.iso8601(6),
            "last_error" => nil
          }
        }
      rescue Hive::TaskClosure::VerificationFailed,
             Hive::TaskClosure::InvalidReceipt,
             Hive::ConcurrentRunError => e
        {
          status: :blocked,
          archive: { "status" => "blocked", "last_error" => bounded_error(e) },
          next_poll_at: now + @poll_interval_sec
        }
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

      def remote_result(facts, candidate, now:)
        state = facts.fetch("state").to_s.upcase
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

      def ensure_architecture_intake(identity, candidate, remote, now:)
        current = candidate.fetch("architecture")
        return { status: :ready, architecture: current } if
          %w[accepted not_required].include?(current["status"])

        receipt = @merge_intake&.ingest(
          project: identity.fetch("registration"),
          pr: candidate.dig("pull_request", "url"),
          now: now
        )
        if receipt == :deferred
          return {
            status: :deferred,
            remote: remote,
            architecture: current.merge(
              "status" => "deferred",
              "last_error" => "architecture intake deferred by its bounded tick budget"
            ),
            next_poll_at: now + @poll_interval_sec
          }
        end
        architecture = if receipt.nil?
          current.merge("status" => "not_required", "last_error" => nil)
        else
          current.merge(
            "status" => "accepted",
            "request_id" => receipt["job_id"]&.to_s,
            "receipt" => architecture_receipt(receipt),
            "last_error" => nil
          )
        end
        { status: :ready, architecture: architecture }
      rescue StandardError => e
        {
          status: :deferred,
          remote: remote,
          architecture: current.merge(
            "status" => "failed", "last_error" => bounded_error(e)
          ),
          next_poll_at: now + @poll_interval_sec
        }
      end

      def apply_result!(candidate, result, now:)
        candidate["remote"].merge!(result[:remote]) if result[:remote]
        candidate["architecture"].merge!(result[:architecture]) if result[:architecture]
        candidate["archive"].merge!(result[:archive]) if result[:archive]
        candidate["updated_at"] = now.utc.iso8601(6)
        if result[:status] == :failed
          @store.record_failure!(candidate, Hive::Error.new(result[:reason]), now: now)
        elsif result[:next_poll_at]
          candidate["retry"] = {
            "failures" => candidate.dig("retry", "failures").to_i,
            "not_before" => result.fetch(:next_poll_at).utc.iso8601(6)
          }
        else
          @store.clear_retry!(candidate)
        end
      end

      # Persist each externally-observed phase before starting the next one.
      # A daemon crash after GitHub verification or architecture acceptance
      # therefore resumes from that receipt instead of repeating the earlier
      # side effect.
      def checkpoint!(identity, candidate, result, now:)
        @store.transaction(identity, now: now) do |state|
          current = state.fetch("candidates")[candidate.fetch("key")]
          unless current &&
                 current.dig("observation", "task_generation") ==
                   candidate.dig("observation", "task_generation")
            raise Hive::ConcurrentRunError,
                  "merge reconciliation candidate changed before checkpoint"
          end

          apply_result!(current, result, now: now)
        end
        apply_result!(candidate, result, now: now)
      end

      def terminal_result(task, identity, now:)
        closure = Hive::TaskClosure.read(task, project: identity.fetch("registration"))
        if closure.valid?
          {
            status: :already_archived,
            archive: {
              "status" => "archived",
              "receipt_digest" => closure.receipt.fetch("receipt_digest"),
              "archived_at" => now.utc.iso8601(6),
              "last_error" => nil
            }
          }
        else
          {
            status: :blocked,
            archive: {
              "status" => "blocked",
              "last_error" => "terminal task has no valid merge closure receipt"
            },
            next_poll_at: now + @poll_interval_sec
          }
        end
      end

      def mark_terminal_candidate(candidate, identity, now:)
        task = Hive::TaskResolver.new(
          candidate.dig("task", "slug"),
          project_filter: identity.fetch("registration")
        ).resolve
        result = terminal_result(task, identity, now: now)
        apply_result!(candidate, result, now: now)
      rescue Hive::Error
        nil
      end

      def generation_current?(task, candidate)
        marker = Hive::Markers.current(task.state_file)
        Hive::TaskClosure.task_generation(task, marker: marker) ==
          candidate.dig("observation", "task_generation") &&
          Hive::TaskClosure.marker_generation(marker) ==
            candidate.dig("observation", "marker_generation")
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
          row.workflow.to_s == "coding"
      end

      def backlog_outcome(row, task_generation, status:, reason:,
                          candidate_key:, now:)
        key = @store.outcome_key(
          project: row.project,
          slug: row.slug,
          task_generation: task_generation
        )
        {
          "key" => key,
          "project" => row.project.to_s,
          "slug" => row.slug.to_s,
          "stage" => row.stage.to_s,
          "task_generation" => task_generation,
          "status" => status,
          "reason" => blank_to_nil(reason),
          "candidate_key" => candidate_key,
          "observed_at" => now.utc.iso8601(6)
        }
      end

      def held_row?(row)
        row.blocked == true || !row.admission_error.nil?
      end

      def hold_reason(row)
        return row.admission_error.reason_code.to_s unless row.admission_error.nil?
        return "dependency_blocked" if row.blocked == true

        nil
      end

      def terminal_row?(row)
        row.stage.to_s == Hive::Stages::DIRS.last
      end

      def merge_observation(existing, observed)
        return observed unless existing

        merged = existing.merge(
          "task" => observed.fetch("task"),
          "observation" => observed.fetch("observation"),
          "updated_at" => observed.fetch("updated_at")
        )
        old_pr = existing.fetch("pull_request")
        new_pr = observed.fetch("pull_request")
        if %w[pull_request_binding_changed observed_head_changed].include?(
          existing.dig("observation", "hold_reason")
        )
          merged["observation"]["held"] = true
          merged["observation"]["hold_reason"] =
            existing.dig("observation", "hold_reason")
          return merged
        end
        binding_changed = %w[url host repository number].any? do |field|
          old_pr[field] != new_pr[field]
        end
        old_head = old_pr["observed_head"]
        new_head = new_pr["observed_head"]
        head_changed = old_head && new_head && old_head != new_head
        if binding_changed || head_changed
          merged["observation"]["held"] = true
          merged["observation"]["hold_reason"] =
            binding_changed ? "pull_request_binding_changed" : "observed_head_changed"
          return merged
        end

        return merged if old_head || new_head.nil?

        merged["pull_request"] = old_pr.merge("observed_head" => new_head)
        merged["remote"] = {
          "state" => "unknown", "merge_oid" => nil,
          "merged_at" => nil, "observed_at" => nil
        }
        merged["archive"] = merged.fetch("archive").merge(
          "status" => "pending", "last_error" => nil
        )
        merged
      end

      def binding_drift?(existing, observed)
        old_pr = existing.fetch("pull_request")
        new_pr = observed.fetch("pull_request")
        return true if %w[url host repository number].any? do |field|
          old_pr[field] != new_pr[field]
        end

        old_head = old_pr["observed_head"]
        new_head = new_pr["observed_head"]
        !old_head.nil? && old_head != new_head
      end

      def binding_drift_reason(existing, observed)
        old_pr = existing.fetch("pull_request")
        new_pr = observed.fetch("pull_request")
        changed = %w[url host repository number].any? do |field|
          old_pr[field] != new_pr[field]
        end
        changed ? "pull_request_binding_changed" : "observed_head_changed"
      end

      def candidates_for(project)
        identity = @contexts[project.to_s] || identity_for(project)
        @contexts[project.to_s] = identity
        @store.load(identity)&.fetch("candidates", {})&.values || []
      rescue StandardError
        []
      end

      def each_candidate
        @contexts.keys.flat_map { |project| candidates_for(project) }
      end

      def parse_pr_url(value)
        Hive::Gh.parse_pull_request_url(value)
      end

      def read_pr_url(task)
        Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"].to_s
      end

      def observed_head_for(task, identity, frontmatter)
        Hive::TaskClosure.local_pr_head_binding(
          task,
          frontmatter: frontmatter,
          project_root: identity.fetch("project_path")
        )
      end

      def stage_dir(task)
        "#{task.stage_index}-#{task.stage_name}"
      end

      def architecture_receipt(receipt)
        value = receipt["manifest_digest"] || receipt["job_id"] ||
                Digest::SHA256.hexdigest(JSON.generate(receipt))
        value.to_s[0, 256]
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
        "#{error.class}: #{error.message}"[0, PrMergeReconciliationStore::MAX_DIAGNOSTIC_BYTES]
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
