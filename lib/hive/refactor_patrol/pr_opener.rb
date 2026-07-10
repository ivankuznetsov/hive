require "json"
require "open3"
require "tempfile"
require "uri"
require "hive/gh"
require "hive/patrol/finding"
require "hive/patrol/review_handoff"
require "hive/secret_patterns"

module Hive
  module RefactorPatrol
    # Publishes one validated thesis branch and makes the mandatory 6-review
    # handoff. A durable caller records creation intent before #open invokes
    # gh; after an ambiguous create result, retries reconcile only.
    class PrOpener
      Result = Struct.new(:outcome, :terminal, :pr_url, :review_task_path, :receipts, keyword_init: true)

      MAX_TITLE = 200
      MAX_BODY = 20_000

      def initialize(project_root, cfg:, gh: Hive::Gh, review_handoff: nil, diff_reader: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @gh = gh
        @review_handoff = review_handoff || Hive::Patrol::ReviewHandoff.new(
          @project_root, cfg: cfg, state: {}
        )
        @diff_reader = diff_reader || method(:branch_diff)
      end

      def open(thesis:, patch:, job_id:, canonical_action_id:, source:,
               record_intent:, creation_attempted: false)
        intent_persisted = false
        return result("patch_not_publishable", true) unless patch.publishable?
        assert_patch_identity!(patch)
        unless current_head == patch.publication_base_sha
          return result("trunk_drift_retry", false, receipts: patch_receipts(patch))
        end

        @gh.ensure_authenticated!(@cfg)
        existing = @gh.lookup_prs_for_branch(patch.worktree_path, patch.branch, cfg: @cfg)
        matched = existing.min_by { |pr| remote_pr_number(pr) }
        if matched
          return reconcile_existing(
            matched, thesis, patch, job_id, canonical_action_id, source
          )
        end
        if creation_attempted
          return result(
            "remote_outcome_unknown", false,
            receipts: patch_receipts(patch).merge("creation_intent" => true)
          )
        end

        body = body_for(thesis, patch, job_id, canonical_action_id, source)
        diff = @diff_reader.call(patch)
        hits = Hive::SecretPatterns.scan(body) + Hive::SecretPatterns.scan(diff)
        return result("secret_detected", true, receipts: patch_receipts(patch)) if hits.any?

        @gh.push_branch!(patch.worktree_path, patch.branch, cfg: @cfg)
        begin
          intent_receipt = record_intent.call
        rescue StandardError => e
          return result(
            "intent_persist_failed", false,
            receipts: patch_receipts(patch).merge("intent_error" => "#{e.class}: #{e.message}")
          )
        end
        unless intent_receipt.equal?(true)
          return result(
            "intent_persist_failed", false,
            receipts: patch_receipts(patch).merge("intent_receipt" => "not_true")
          )
        end
        intent_persisted = true
        pr_url = create_pr(patch, source, title_for(thesis), body)
        handoff(thesis, patch, pr_url, job_id, canonical_action_id, source)
      rescue Hive::GhError => e
        outcome = intent_persisted || creation_attempted ? "remote_outcome_unknown" : "gh_error"
        result(outcome, false, receipts: patch_receipts(patch).merge("error" => e.message))
      end

      private

      def reconcile_existing(pr, thesis, patch, job_id, action_id, source)
        conflicts = remote_conflicts(pr, thesis, patch, job_id, action_id, source)
        unless conflicts.empty?
          return result(
            "remote_pr_conflict", false,
            receipts: patch_receipts(patch).merge(
              "remote_pr_url" => pr.is_a?(Hash) ? pr["url"] : nil,
              "remote_conflicts" => conflicts
            ).compact
          )
        end

        url = pr.fetch("url")
        case pr.fetch("state")
        when "OPEN"
          handoff(thesis, patch, url, job_id, action_id, source)
        when "MERGED"
          handoff(
            thesis, patch, url, job_id, action_id, source,
            success_outcome: "merged", failure_outcome: "merged_without_review_handoff"
          )
        else
          result(
            "closed_without_merge", true, pr_url: url,
            receipts: patch_receipts(patch).merge("pr_url" => url)
          )
        end
      end

      def handoff(thesis, patch, pr_url, job_id, action_id, source,
                  success_outcome: "pr_opened", failure_outcome: "review_handoff_pending")
        finding = finding_for(thesis, job_id)
        task_path = @review_handoff.enqueue(
          finding: finding, patch: patch, pr_url: pr_url, now: Time.now, mandatory: true,
          context: handoff_context(thesis, patch, job_id, action_id, source)
        )
        unless task_path
          return result(
            failure_outcome, false, pr_url: pr_url,
            receipts: patch_receipts(patch).merge("pr_url" => pr_url)
          )
        end
        result(
          success_outcome, true, pr_url: pr_url, review_task_path: task_path,
          receipts: patch_receipts(patch).merge("pr_url" => pr_url, "review_task_path" => task_path)
        )
      rescue StandardError => e
        result(
          failure_outcome, false, pr_url: pr_url,
          receipts: patch_receipts(patch).merge("pr_url" => pr_url, "handoff_error" => "#{e.class}: #{e.message}")
        )
      end

      def create_pr(patch, source, title, body)
        Tempfile.create([ "hive-refactor-pr-", ".md" ]) do |file|
          file.write(body)
          file.flush
          args = [
            "gh", "pr", "create", "--repo", source.fetch("repository"),
            "--base", source.fetch("base_branch"), "--head", patch.branch,
            "--title", title, "--body-file", file.path
          ]
          out, err, status = @gh.capture3(*args, chdir: patch.worktree_path, cfg: @cfg)
          unless status.success?
            raise Hive::GhError, "gh pr create failed: #{err.to_s.strip.empty? ? out : err}"
          end

          url = out.lines.last.to_s.strip
          unless valid_pr_url_identity?(url, source)
            raise Hive::GhError, "gh pr create returned no valid pull-request URL"
          end

          url
        end
      end

      def body_for(thesis, patch, job_id, action_id, source)
        content = <<~MD
          ## Architecture patrol refactor

          Source PR: #{source.fetch("url")}
          Job: `#{job_id}`
          Thesis: `#{thesis.id}`
          Fingerprint: `#{thesis.fingerprint}`

          ### Problem and cost

          #{thesis.problem}

          #{thesis.cost}

          ### Refactor

          #{thesis.proposed_refactor}

          ### Validation

          #{validation_lines(patch.validation)}

          Changed paths: #{Array(patch.changed_paths).join(", ")}
          Diff lines: #{patch.diff_lines}

        MD
        marker = action_marker(thesis, job_id, action_id)
        suffix = "\n#{marker}\n"
        prefix = content.to_s.b.byteslice(0, MAX_BODY - suffix.bytesize).to_s
        "#{prefix.force_encoding(Encoding::UTF_8).scrub("")}#{suffix}"
      end

      def validation_lines(validation)
        Array(validation && validation["commands"]).map do |command|
          "- #{command['name']}: #{command['exit_code'].to_i.zero? ? 'passed' : 'failed'}"
        end.join("\n")
      end

      def title_for(thesis)
        "Architecture patrol: #{thesis.problem.to_s.lines.first.to_s.strip}"[0, MAX_TITLE]
      end

      def finding_for(thesis, job_id)
        Hive::Patrol::Finding.new(
          id: "#{job_id}:#{thesis.id}", feature_id: thesis.feature_id,
          category: "architecture", severity: "medium", confidence: thesis.confidence,
          title: thesis.problem.to_s.lines.first.to_s.strip,
          description: "#{thesis.problem}\n\nCost: #{thesis.cost}",
          recommendation: thesis.proposed_refactor, evidence: Array(thesis.evidence),
          fingerprint: thesis.fingerprint
        )
      end

      def handoff_context(thesis, patch, job_id, action_id, source)
        {
          "thesis" => thesis.to_h,
          "source_pr" => stringify_keys(source),
          "job_id" => job_id,
          "canonical_action_id" => action_id,
          "patch" => patch_receipts(patch)
        }
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def action_marker(thesis, job_id, action_id)
        "<!-- hive-refactor-patrol action=#{action_id} job=#{job_id} fingerprint=#{thesis.fingerprint} -->"
      end

      def remote_pr_number(pr)
        return -1 unless pr.is_a?(Hash) && pr["number"].is_a?(Integer) && pr["number"].positive?

        pr.fetch("number")
      end

      def remote_conflicts(pr, thesis, patch, job_id, action_id, source)
        return [ "invalid_record" ] unless pr.is_a?(Hash)

        conflicts = []
        conflicts << "number" unless pr["number"].is_a?(Integer) && pr["number"].positive?
        conflicts << "state" unless %w[OPEN MERGED CLOSED].include?(pr["state"])
        conflicts << "action_marker" unless exact_marker?(pr["body"], action_marker(thesis, job_id, action_id))
        remote_head = pr["headRefOid"].to_s
        conflicts << "head_sha" if remote_head.empty? || remote_head != patch.commit_sha
        conflicts << "base_branch" unless pr["baseRefName"] == source.fetch("base_branch")
        conflicts << "head_repository" unless head_repository(pr) == source.fetch("repository")
        unless valid_pr_url_identity?(pr["url"], source, expected_number: pr["number"])
          conflicts << "url_repository"
        end
        conflicts
      end

      def exact_marker?(body, marker)
        body.is_a?(String) && body.lines.any? { |line| line.strip == marker }
      end

      def head_repository(pr)
        repository = pr["headRepository"]
        repository.is_a?(Hash) ? repository["nameWithOwner"] : nil
      end

      def valid_pr_url_identity?(url, source, expected_number: nil)
        uri = URI.parse(url.to_s)
        source_uri = URI.parse(source.fetch("url").to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        return false unless uri.is_a?(URI::HTTP) && source_uri.is_a?(URI::HTTP) && match
        return false unless uri.scheme == source_uri.scheme && uri.host&.casecmp?(source_uri.host.to_s)
        return false unless match[1] == source.fetch("repository")
        return false unless uri.query.nil? && uri.fragment.nil?
        return false if expected_number && (!expected_number.is_a?(Integer) || match[2].to_i != expected_number)

        true
      rescue KeyError, URI::InvalidURIError
        false
      end

      def branch_diff(patch)
        out, err, status = Open3.capture3(
          "git", "-C", patch.worktree_path, "diff",
          "#{patch.publication_base_sha}..#{patch.commit_sha}"
        )
        raise Hive::GitError, "cannot read refactor PR diff: #{err}" unless status.success?

        out
      end

      def assert_patch_identity!(patch)
        branch = git_output!(patch.worktree_path, "branch", "--show-current").strip
        head = git_output!(patch.worktree_path, "rev-parse", "HEAD").strip
        status = git_output!(patch.worktree_path, "status", "--porcelain=v1", "-z")
        raise Hive::GitError, "refactor patch branch changed before publication" unless branch == patch.branch
        raise Hive::GitError, "refactor patch commit changed before publication" unless head == patch.commit_sha
        raise Hive::GitError, "refactor patch worktree is dirty before publication" unless status.empty?

        _out, err, ancestry = Open3.capture3(
          "git", "-C", patch.worktree_path, "merge-base", "--is-ancestor",
          patch.publication_base_sha, patch.commit_sha
        )
        return if ancestry.success?

        raise Hive::GitError, "refactor patch does not descend from publication base: #{err}"
      end

      def current_head
        git_output!(@project_root, "rev-parse", "HEAD").strip
      end

      def git_output!(directory, *args)
        out, err, status = Open3.capture3("git", "-C", directory, *args)
        return out if status.success?

        raise Hive::GitError, "git #{args.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
      end

      def patch_receipts(patch)
        {
          "branch" => patch.branch, "worktree_path" => patch.worktree_path,
          "analysis_sha" => patch.analysis_sha, "publication_base_sha" => patch.publication_base_sha,
          "commit_sha" => patch.commit_sha, "validation" => patch.validation,
          "changed_paths" => patch.changed_paths, "diff_lines" => patch.diff_lines
        }
      end

      def result(outcome, terminal, pr_url: nil, review_task_path: nil, receipts: {})
        Result.new(
          outcome: outcome, terminal: terminal, pr_url: pr_url,
          review_task_path: review_task_path, receipts: receipts
        )
      end
    end
  end
end
