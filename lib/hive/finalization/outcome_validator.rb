require "open3"
require "time"
require "hive/gh"
require "hive/worktree"

module Hive
  module Finalization
    # Validates the three exceptional ways a task may become archive-eligible
    # without observing its handed-off PR as MERGED. The validator is strict by
    # design: unavailable or ambiguous remote evidence is a refusal, never an
    # approximation.
    class OutcomeValidator
      class InvalidOutcome < Hive::InvalidTaskPath; end
      class NotEligible < Hive::Finalization::Error; end

      OUTCOMES = Hive::Finalization::Event::NO_PR_OUTCOMES.freeze
      SHA_PATTERN = /\A[0-9a-f]{40,64}\z/.freeze
      BRANCH_PATTERN = /\A(?!-)(?!.*\.\.)(?!.*(?:\A|\/)\.)(?!.*[~^:?*\[\\\s])[^\x00-\x1f\x7f]+\z/.freeze

      def initialize(snapshot_loader: ->(url, cfg) { Hive::Gh.exact_pr_snapshot(url, cfg: cfg) },
                     landing_checker: nil, clock: -> { Time.now.utc })
        @snapshot_loader = snapshot_loader
        @landing_checker = landing_checker || method(:commit_landed?)
        @clock = clock
      end

      def validate!(outcome:, evidence:, finalization:, job:, current_snapshot:, task:, cfg:)
        normalized = outcome.to_s.strip
        unless OUTCOMES.include?(normalized)
          raise InvalidOutcome, "outcome must be one of: #{OUTCOMES.join(', ')}"
        end

        validate_current_authority!(finalization, job, current_snapshot, task)
        validate_no_mutation_owner!(job)

        case normalized
        when "abandonment"
          validate_abandonment!(evidence, current_snapshot)
        when "superseded"
          validate_superseded!(evidence, current_snapshot, cfg)
        when "direct_landing"
          validate_direct_landing!(evidence, finalization, current_snapshot, task, cfg)
        end
      end

      private

      def validate_current_authority!(finalization, job, snapshot, task)
        unless %w[finalized babysitter_active blocked merge_ready].include?(finalization["state"])
          raise NotEligible, "no-PR approval is invalid from #{finalization['state'].inspect}"
        end
        unless task.stage_index == 8 && task.stage_name == "finalize"
          raise NotEligible, "no-PR approval requires a task in 8-finalize"
        end

        identity = job.fetch("identity")
        mismatches = []
        mismatches << "job" unless job["job_id"] == finalization["job_id"]
        mismatches << "task slug" unless identity["task_slug"] == task.slug
        mismatches << "task generation" unless identity["task_generation"] == finalization["task_generation"]
        mismatches << "repository" unless snapshot.repository == finalization["repository"] &&
                                                identity["repository"] == finalization["repository"]
        mismatches << "PR number" unless snapshot.number == finalization["pr_number"] &&
                                               identity["pr_number"] == finalization["pr_number"]
        mismatches << "PR URL" unless snapshot.url == finalization["pr_url"] &&
                                            job["pr_url"] == finalization["pr_url"]
        mismatches << "head SHA" unless snapshot.head_sha == finalization["head_sha"] &&
                                             job["head_sha"] == finalization["head_sha"]
        mismatches << "head generation" unless job["head_generation"] == finalization["head_generation"]
        unless job["finalize_attempt_id"] == finalization["finalize_attempt_id"]
          mismatches << "finalize attempt"
        end
        return if mismatches.empty?

        raise NotEligible, "no-PR approval has stale #{mismatches.join(', ')} evidence"
      rescue KeyError => e
        raise NotEligible, "no-PR approval authority is missing #{e.key}"
      end

      def validate_no_mutation_owner!(job)
        live = Array(job["claims"]).any? do |claim|
          next false unless claim["state"] == "active"

          Time.iso8601(claim.fetch("expires_at")) > @clock.call
        end
        raise NotEligible, "current babysitter claim can still mutate the PR branch" if live
      rescue ArgumentError, KeyError
        raise NotEligible, "current babysitter claim evidence is invalid"
      end

      def validate_abandonment!(evidence, snapshot)
        unless evidence.to_s.strip.empty?
          raise InvalidOutcome, "abandonment derives evidence from the current PR; omit --evidence"
        end
        require_closed_unmerged!(snapshot)
        current_pr_evidence(snapshot).merge(
          "kind" => "abandonment",
          "verified" => true,
          "no_live_claim" => true
        )
      end

      def validate_superseded!(evidence, current_snapshot, cfg)
        require_closed_unmerged!(current_snapshot)
        landed_url = evidence.to_s.strip
        raise InvalidOutcome, "superseded requires --evidence with the landed PR URL" if landed_url.empty?

        landed = @snapshot_loader.call(landed_url, cfg)
        unless landed.state == "MERGED" && !landed.merged_at.to_s.empty?
          raise NotEligible, "superseding PR is not explicitly merged"
        end
        unless landed.repository == current_snapshot.repository && landed.base_branch == current_snapshot.base_branch
          raise NotEligible, "superseding PR does not land in the current repository and target branch"
        end
        if landed.number == current_snapshot.number
          raise NotEligible, "superseding PR must differ from the current closed PR"
        end

        current_pr_evidence(current_snapshot).merge(
          "kind" => "superseded",
          "verified" => true,
          "landed_pr" => snapshot_evidence(landed)
        )
      end

      def validate_direct_landing!(evidence, finalization, current_snapshot, task, cfg)
        require_closed_unmerged!(current_snapshot)
        commit = evidence.to_s.strip.downcase
        raise InvalidOutcome, "direct_landing requires --evidence with the recorded work commit" if commit.empty?
        raise InvalidOutcome, "direct_landing evidence must be a full commit SHA" unless commit.match?(SHA_PATTERN)
        unless commit == finalization["head_sha"]
          raise NotEligible, "direct landing commit does not match the recorded work head"
        end
        unless @landing_checker.call(task.worktree_path || task.project_root, commit, current_snapshot.base_branch, cfg)
          raise NotEligible, "recorded work commit is not contained in the current remote target"
        end

        current_pr_evidence(current_snapshot).merge(
          "kind" => "direct_landing",
          "verified" => true,
          "commit_sha" => commit,
          "target_branch" => current_snapshot.base_branch
        )
      end

      def require_closed_unmerged!(snapshot)
        return if snapshot.state == "CLOSED" && snapshot.merged_at.to_s.empty?

        raise NotEligible, "exceptional no-PR approval requires the current PR to be closed without merge"
      end

      def current_pr_evidence(snapshot)
        {
          "current_pr" => snapshot_evidence(snapshot),
          "validated_at" => @clock.call.utc.iso8601(6)
        }
      end

      def snapshot_evidence(snapshot)
        {
          "repository" => snapshot.repository,
          "number" => snapshot.number,
          "url" => snapshot.url,
          "state" => snapshot.state,
          "head_sha" => snapshot.head_sha,
          "base_branch" => snapshot.base_branch,
          "merged_at" => snapshot.merged_at,
          "observed_at" => snapshot.observed_at
        }
      end

      def commit_landed?(worktree_path, commit, base_branch, _cfg)
        branch = base_branch.to_s
        unless branch.match?(BRANCH_PATTERN)
          raise NotEligible, "remote target branch is invalid"
        end
        path = File.expand_path(worktree_path.to_s)
        unless File.directory?(path)
          raise NotEligible, "task recovery worktree is unavailable for direct landing proof"
        end

        refspec = "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"
        _out, err, fetch = Open3.capture3(
          Hive::Worktree::NONINTERACTIVE_FETCH_ENV,
          "git", "-C", path, "fetch", "--no-tags", "origin", refspec
        )
        unless fetch.success?
          raise NotEligible, "could not verify current remote target: #{bounded(err)}"
        end
        _out, err, contained = Open3.capture3(
          "git", "-C", path, "merge-base", "--is-ancestor", commit, "refs/remotes/origin/#{branch}"
        )
        return true if contained.success?
        return false if contained.exitstatus == 1

        raise NotEligible, "could not compare direct landing evidence: #{bounded(err)}"
      rescue SystemCallError => e
        raise NotEligible, "could not verify direct landing evidence: #{e.class}: #{e.message}"
      end

      def bounded(value)
        value.to_s.gsub(/\s+/, " ").strip[0, 200]
      end
    end
  end
end
