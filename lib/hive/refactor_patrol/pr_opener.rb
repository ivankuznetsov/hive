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
      PUSH_INTENT = "push_intent".freeze
      PUSH_COMPLETE = "push_complete".freeze
      PR_CREATE_INTENT = "pr_create_intent".freeze

      class << self
        def push_intent_payload(canonical_action_id:, repository:, branch:, commit_sha:,
                                expected_remote_oid:)
          {
            "operation" => "push_branch",
            "canonical_action_id" => canonical_action_id,
            "repository" => repository,
            "branch" => branch,
            "commit_sha" => commit_sha,
            "expected_remote_oid" => expected_remote_oid
          }
        end

        def push_complete_payload(canonical_action_id:, repository:, branch:, commit_sha:)
          {
            "operation" => "push_branch_complete",
            "canonical_action_id" => canonical_action_id,
            "repository" => repository,
            "branch" => branch,
            "commit_sha" => commit_sha,
            "remote_oid" => commit_sha
          }
        end

        def pr_create_intent_payload(canonical_action_id:, repository:, branch:, commit_sha:)
          {
            "operation" => "create_pr",
            "canonical_action_id" => canonical_action_id,
            "repository" => repository,
            "branch" => branch,
            "commit_sha" => commit_sha
          }
        end
      end

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
               record_intent:, creation_attempted: false,
               publication_state: nil,
               authorize_push: -> { true }, authorize_create: -> { true },
               authorize_handoff: -> { true },
               superseded_patch_commits: [])
        request_phase = nil
        return result("patch_not_publishable", true) unless patch.publishable?
        assert_patch_identity!(patch)

        repository = source.fetch("repository")
        host = source_github_host!(source, repository)
        publication = normalize_publication_state(publication_state, creation_attempted)
        unless valid_publication_state?(publication, patch, canonical_action_id, repository)
          return result("invalid_publication_state", false)
        end
        @gh.ensure_authenticated!(@cfg, host: host)
        existing = @gh.lookup_prs_for_branch(
          patch.worktree_path, patch.branch,
          repository: repository, host: host, cfg: @cfg
        )
        reconciliation = reconcile_remote_set(
          existing, thesis, patch, job_id, canonical_action_id, source,
          authorize_handoff
        )
        return reconciliation if reconciliation

        return result("remote_outcome_unknown", false) if publication.key?(PR_CREATE_INTENT)

        new_push = !publication.key?(PUSH_INTENT) && !publication.key?(PUSH_COMPLETE)
        if new_push && current_head != patch.publication_base_sha
          return result("trunk_drift_retry", false)
        end

        body = body_for(thesis, patch, job_id, canonical_action_id, source)
        diff = @diff_reader.call(patch)
        hits = Hive::SecretPatterns.scan(body) + Hive::SecretPatterns.scan(diff)
        return result("secret_detected", true) if hits.any?

        remote_url = @gh.origin_push_url(patch.worktree_path, cfg: @cfg)
        identity = @gh.repository_identity_from_remote(remote_url)
        unless identity["repository"].to_s.casecmp?(repository.to_s) &&
               identity["host"].to_s.casecmp?(host.to_s)
          return result("repository_identity_drift", false)
        end
        remote_oid = @gh.remote_branch_oid(
          patch.worktree_path, patch.branch, cfg: @cfg, remote: remote_url
        )
        replaceable_oids = normalized_superseded_patch_commits(superseded_patch_commits)
        expected_oid = publication.dig(PUSH_INTENT, "expected_remote_oid")
        if publication.key?(PUSH_INTENT) && remote_oid != patch.commit_sha && remote_oid != expected_oid
          return result("remote_branch_conflict", false)
        end
        if remote_oid && remote_oid != patch.commit_sha && !replaceable_oids.include?(remote_oid)
          return result("remote_branch_conflict", false)
        end

        if remote_oid == patch.commit_sha
          unless publication.key?(PUSH_COMPLETE)
            persisted = persist_publication(
              record_intent, PUSH_COMPLETE,
              self.class.push_complete_payload(
                canonical_action_id: canonical_action_id,
                repository: repository, branch: patch.branch,
                commit_sha: patch.commit_sha
              )
            )
            return persistence_failure(persisted, request_sent: publication.key?(PUSH_INTENT)) unless persisted == true
          end
        else
          return result("authority_revoked", false) unless authorize_push.call.equal?(true)

          push_intent = self.class.push_intent_payload(
            canonical_action_id: canonical_action_id,
            repository: repository, branch: patch.branch,
            commit_sha: patch.commit_sha, expected_remote_oid: remote_oid
          )
          persisted = persist_publication(record_intent, PUSH_INTENT, push_intent)
          return persistence_failure(persisted, request_sent: false) unless persisted == true
          return result("authority_revoked", false) unless authorize_push.call.equal?(true)

          request_phase = PUSH_INTENT
          @gh.push_branch!(
            patch.worktree_path, patch.branch, cfg: @cfg,
            expected_remote_oid: remote_oid,
            expected_remote_absent: remote_oid.nil?, remote: remote_url,
            set_upstream: false
          )
          persisted = persist_publication(
            record_intent, PUSH_COMPLETE,
            self.class.push_complete_payload(
              canonical_action_id: canonical_action_id,
              repository: repository, branch: patch.branch,
              commit_sha: patch.commit_sha
            )
          )
          return persistence_failure(persisted, request_sent: true) unless persisted == true

          request_phase = nil
        end

        return result("authority_revoked", false) unless authorize_create.call.equal?(true)
        unless exact_remote_head?(patch, remote_url)
          return result("remote_branch_conflict", false)
        end

        create_intent = self.class.pr_create_intent_payload(
          canonical_action_id: canonical_action_id,
          repository: repository, branch: patch.branch,
          commit_sha: patch.commit_sha
        )
        persisted = persist_publication(record_intent, PR_CREATE_INTENT, create_intent)
        return persistence_failure(persisted, request_sent: false) unless persisted == true
        return result("authority_revoked", false) unless authorize_create.call.equal?(true)
        unless exact_remote_head?(patch, remote_url)
          return result(
            "remote_outcome_unknown", false,
            receipts: { "error" => "remote branch changed after PR-create intent" }
          )
        end

        request_phase = PR_CREATE_INTENT
        pr_url = create_pr(patch, source, title_for(thesis), body)
        @gh.verify_pr_identity!(
          pr_url,
          repository: repository,
          host: host,
          branch: patch.branch,
          head_oid: patch.commit_sha,
          base_branch: source.fetch("base_branch"),
          cfg: @cfg
        )
        handoff(
          thesis, patch, pr_url, job_id, canonical_action_id, source,
          authorize_handoff: authorize_handoff
        )
      rescue Hive::GhError => e
        outcome = request_phase ? "remote_outcome_unknown" : "gh_error"
        result(outcome, false, receipts: { "error" => e.message })
      rescue StandardError => e
        raise unless request_phase

        result(
          "remote_outcome_unknown", false,
          receipts: { "error" => "#{e.class}: #{e.message}" }
        )
      end

      private

      def reconcile_remote_set(prs, thesis, patch, job_id, action_id, source,
                               authorize_handoff)
        return nil if prs.empty?

        classified = prs.map do |pr|
          { record: pr, conflicts: remote_conflicts(pr, thesis, patch, job_id, action_id, source) }
        end
        matches = classified.select { |candidate| candidate.fetch(:conflicts).empty? }
        if matches.one?
          return reconcile_existing(
            matches.first.fetch(:record), thesis, patch, job_id, action_id, source,
            authorize_handoff
          )
        end
        if matches.size > 1
          return result(
            "remote_pr_conflict", false,
            receipts: {
              "remote_conflicts" => [ "multiple_identity_matches" ],
              "matching_pr_numbers" => matches.map { |candidate| remote_pr_number(candidate.fetch(:record)) }.sort,
              "matching_pr_urls" => matches.filter_map { |candidate| candidate.fetch(:record)["url"] }.sort
            }
          )
        end

        result(
          "remote_pr_conflict", false,
          receipts: {
            "remote_conflicts" => [ "no_identity_match" ],
            "remote_pr_candidates" => visible_remote_candidates(classified)
          }
        )
      end

      def reconcile_existing(pr, thesis, patch, job_id, action_id, source,
                             authorize_handoff)
        url = pr.fetch("url")
        case pr.fetch("state")
        when "OPEN"
          handoff(
            thesis, patch, url, job_id, action_id, source,
            authorize_handoff: authorize_handoff
          )
        when "MERGED"
          handoff(
            thesis, patch, url, job_id, action_id, source,
            authorize_handoff: authorize_handoff,
            success_outcome: "merged", failure_outcome: "merged_without_review_handoff"
          )
        else
          result(
            "closed_without_merge", true, pr_url: url,
            receipts: { "pr_url" => url }
          )
        end
      end

      def handoff(thesis, patch, pr_url, job_id, action_id, source,
                  authorize_handoff:,
                  success_outcome: "pr_opened", failure_outcome: "review_handoff_pending")
        unless authorize_handoff.call.equal?(true)
          return result(
            failure_outcome, false, pr_url: pr_url,
            receipts: { "pr_url" => pr_url }
          )
        end
        finding = finding_for(thesis, job_id)
        task_path = @review_handoff.enqueue(
          finding: finding, patch: patch, pr_url: pr_url, now: Time.now, mandatory: true,
          context: handoff_context(thesis, patch, job_id, action_id, source)
        )
        unless task_path
          return result(
            failure_outcome, false, pr_url: pr_url,
            receipts: { "pr_url" => pr_url }
          )
        end
        result(
          success_outcome, true, pr_url: pr_url, review_task_path: task_path,
          receipts: { "pr_url" => pr_url, "review_task_path" => task_path }
        )
      rescue StandardError => e
        result(
          failure_outcome, false, pr_url: pr_url,
          receipts: { "pr_url" => pr_url, "handoff_error" => "#{e.class}: #{e.message}" }
        )
      end

      def create_pr(patch, source, title, body)
        repository = source.fetch("repository")
        host = source_github_host!(source, repository)
        Tempfile.create([ "hive-refactor-pr-", ".md" ]) do |file|
          file.write(body)
          file.flush
          args = [
            "gh", "pr", "create", "--repo", "#{host}/#{repository}",
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

      def exact_remote_head?(patch, remote_url)
        @gh.remote_branch_oid(
          patch.worktree_path, patch.branch, cfg: @cfg, remote: remote_url
        ) == patch.commit_sha
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
          "patch" => patch_evidence(patch)
        }
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def action_marker(thesis, job_id, action_id)
        "<!-- hive-refactor-patrol action=#{action_id} job=#{job_id} fingerprint=#{thesis.fingerprint} -->"
      end

      def remote_pr_number(pr)
        return -1 unless pr.is_a?(Hash) && pr["number"].is_a?(Integer) && pr["number"].positive?

        pr.fetch("number")
      end

      def visible_remote_candidates(classified)
        classified.sort_by do |candidate|
          number = remote_pr_number(candidate.fetch(:record))
          number.positive? ? [ 0, number ] : [ 1, 0 ]
        end.map do |candidate|
          pr = candidate.fetch(:record)
          {
            "number" => remote_pr_number(pr),
            "url" => pr.is_a?(Hash) ? pr["url"] : nil,
            "conflicts" => candidate.fetch(:conflicts)
          }.compact
        end
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
        unless head_repository(pr).to_s.casecmp?(source.fetch("repository").to_s)
          conflicts << "head_repository"
        end
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
        return false unless match[1].casecmp?(source.fetch("repository").to_s)
        return false unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        return false if expected_number && (!expected_number.is_a?(Integer) || match[2].to_i != expected_number)

        true
      rescue KeyError, URI::InvalidURIError
        false
      end

      def source_github_host!(source, repository)
        uri = URI.parse(source.fetch("url").to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        valid = uri.is_a?(URI::HTTP) && uri.host && match &&
                match[1].casecmp?(repository.to_s) && uri.userinfo.nil? &&
                uri.query.nil? && uri.fragment.nil?
        raise Hive::GhError, "source PR URL does not match its GitHub repository" unless valid

        uri.host
      rescue KeyError, URI::InvalidURIError
        raise Hive::GhError, "source PR URL is invalid"
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

      def patch_evidence(patch)
        {
          "branch" => patch.branch, "worktree_path" => patch.worktree_path,
          "analysis_sha" => patch.analysis_sha, "publication_base_sha" => patch.publication_base_sha,
          "commit_sha" => patch.commit_sha, "validation" => patch.validation,
          "changed_paths" => patch.changed_paths, "diff_lines" => patch.diff_lines
        }
      end

      def normalized_superseded_patch_commits(values)
        Array(values).map do |value|
          oid = value.to_s.downcase
          unless oid.match?(/\A[0-9a-f]{40,64}\z/)
            raise Hive::GitError, "superseded refactor patch commit is invalid"
          end

          oid
        end.uniq
      end

      def normalize_publication_state(value, creation_attempted)
        state = value.nil? ? {} : value
        return nil unless state.is_a?(Hash)

        normalized = state.each_with_object({}) { |(key, payload), result| result[key.to_s] = payload }
        if normalized.empty? && creation_attempted
          normalized[PR_CREATE_INTENT] = { "legacy" => true }
        end
        normalized
      end

      def valid_publication_state?(state, patch, action_id, repository)
        return false unless state.is_a?(Hash)
        return false unless (state.keys - [ PUSH_INTENT, PUSH_COMPLETE, PR_CREATE_INTENT ]).empty?

        push = state[PUSH_INTENT]
        if push
          expected_oid = push.is_a?(Hash) ? push["expected_remote_oid"] : :invalid
          return false unless expected_oid.nil? || expected_oid.to_s.match?(/\A[0-9a-f]{40,64}\z/)
          return false unless push == self.class.push_intent_payload(
            canonical_action_id: action_id, repository: repository,
            branch: patch.branch, commit_sha: patch.commit_sha,
            expected_remote_oid: expected_oid
          )
        end

        complete = state[PUSH_COMPLETE]
        if complete
          return false unless complete == self.class.push_complete_payload(
            canonical_action_id: action_id, repository: repository,
            branch: patch.branch, commit_sha: patch.commit_sha
          )
        end

        create = state[PR_CREATE_INTENT]
        return true if create == { "legacy" => true }
        return true unless create

        create == self.class.pr_create_intent_payload(
          canonical_action_id: action_id, repository: repository,
          branch: patch.branch, commit_sha: patch.commit_sha
        )
      end

      def persist_publication(callback, phase, payload)
        if callback.respond_to?(:parameters) && callback.parameters.empty?
          return true if phase == PUSH_COMPLETE

          callback.call
        else
          callback.call(phase: phase, payload: payload)
        end
      rescue StandardError => e
        e
      end

      def persistence_failure(value, request_sent:)
        outcome = request_sent ? "remote_outcome_unknown" : "intent_persist_failed"
        receipts = if value.is_a?(Exception)
          { "intent_error" => "#{value.class}: #{value.message}" }
        else
          { "intent_receipt" => "not_true" }
        end
        result(outcome, false, receipts: receipts)
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
