require "digest"
require "json"
require "open3"
require "uri"
require "yaml"
require "hive/atomic_file"
require "hive/draft_pr_receipt"
require "hive/gh"
require "hive/markers"
require "hive/secret_patterns"
require "hive/worktree"

module Hive
  module Stages
    # Deterministic controller side of workspace:worktree + handoff:draft_pr.
    # The agent supplies a bounded report and commits; this module alone owns
    # publication, PR identity reconciliation, and terminal markers.
    module DraftPrHandoff
      module_function

      MAX_PR_TITLE_CHARS = 120
      MAX_PR_BODY_CHARS = 8_000
      MAX_SUMMARY_CHARS = 900
      MAX_COMMITS = 64
      MAX_OBJECTS = 2_048
      MAX_OBJECT_BYTES = 2 * 1024 * 1024
      MAX_DIFF_BYTES = 8 * 1024 * 1024
      MAX_SCAN_BYTES = 24 * 1024 * 1024
      MAX_OBJECT_LIST_BYTES = 256 * 1024
      MAX_PATH_LIST_BYTES = 256 * 1024
      RECOVERABLE_REASON = "draft_pr_handoff_failed".freeze
      QUARANTINE_REASON = "draft_pr_quarantined".freeze
      IDENTITY_REASON = "draft_pr_identity_blocked".freeze

      Result = Data.define(:title, :body)

      class QuarantineError < Hive::StageError; end
      class IdentityError < Hive::StageError; end
      class RecoverableError < Hive::StageError; end

      def run!(task, context:, report:, repository_state:, report_source:, cfg: {})
        root = File.dirname(context.worktree_path)
        receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: root)
        receipt = record_agent_validation!(
          task, receipt, report_source, repository_state, root
        )

        if receipt.fetch("phase") == "terminal"
          ensure_terminal_artifacts!(task, receipt)
          return terminal_result(receipt)
        end

        case report.decision
        when :"no-fix"
          terminal!(task, receipt, root, outcome: "no-fix")
          cleanup_no_fix_worktree(task, context)
          { commit: "no_fix", status: :complete, outcome: "no-fix" }
        when :blocked
          terminal!(task, receipt, root, outcome: "blocked", error_reason: "agent_blocked")
          marker_error!(task, "agent_blocked", "Mapped repair agent reported a blocked outcome.")
          { commit: "blocked", status: :error, outcome: "blocked" }
        when :ready
          publish!(task, context, report, report_source, receipt, root, cfg)
        else
          raise IdentityError, "unsupported repair report decision"
        end
      rescue QuarantineError => e
        quarantine!(task, context, e)
      rescue IdentityError => e
        block_identity!(task, context, e)
      rescue RecoverableError, Hive::GhError => e
        recoverable!(task, e)
      end

      def resume_terminal!(task, receipt)
        unless receipt.fetch("phase") == "terminal"
          raise IdentityError, "cannot resume a non-terminal handoff as terminal"
        end

        ensure_terminal_artifacts!(task, receipt)
        terminal_result(receipt)
      end

      def report_source_for_resume(path, expected_sha256:)
        source = File.open(path, File::RDONLY | File::NOFOLLOW, encoding: "UTF-8") do |file|
          raise IdentityError, "fix-report.md must remain a regular file" unless file.stat.file?

          value = file.read(Hive::Stages::AgentReport::MAX_BYTES + 1)
          if value.bytesize > Hive::Stages::AgentReport::MAX_BYTES
            raise IdentityError, "fix-report.md exceeds the validated size limit"
          end
          value
        end
        matches = source.to_enum(:scan, Hive::Markers::MARKER_RE).map { Regexp.last_match }
        if matches.any?
          last = matches.last
          trailing = source[last.end(0)..].to_s
          unless trailing.strip.empty? && %i[complete error].include?(last[:name].downcase.to_sym)
            raise IdentityError, "fix-report.md contains an unexpected controller marker"
          end
          source = source[0...last.begin(0)].rstrip + "\n"
        end
        digest = ::Digest::SHA256.hexdigest(source)
        unless digest == expected_sha256
          raise IdentityError, "fix-report.md changed after agent validation"
        end

        source
      rescue SystemCallError, IOError => e
        raise IdentityError, "fix-report.md is unavailable during handoff resume: #{e.class}"
      end

      def publish!(task, context, report, report_source, receipt, root, cfg)
        preflight_remote!(context, cfg)
        assert_local_identity!(context, receipt.fetch("head_oid"))
        projected = project_report(report)
        scan_sha = scan_publication!(
          context, receipt.fetch("head_oid"), report_source, projected
        )
        if receipt["scan_sha256"] && receipt["scan_sha256"] != scan_sha
          raise IdentityError, "publication scan identity changed after validation"
        end
        unless receipt["scan_sha256"]
          receipt = Hive::DraftPrReceipt.update!(
            task.folder, phase: receipt.fetch("phase"),
            attributes: { "scan_sha256" => scan_sha }, worktree_root: root
          )
        end

        loop do
          receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: root)
          case receipt.fetch("phase")
          when "agent_validated"
            assert_remote_unowned!(context, receipt, cfg)
            receipt = Hive::DraftPrReceipt.advance!(
              task.folder, from: "agent_validated", to: "push_intent",
              attributes: { "push_intent_id" => Hive::DraftPrReceipt.mutation_id },
              worktree_root: root
            )
          when "push_intent"
            receipt = reconcile_or_push!(task, context, receipt, root, cfg)
          when "branch_pushed"
            reconcile_prs!(context, receipt, cfg, allow_owned: false)
            receipt = Hive::DraftPrReceipt.advance!(
              task.folder, from: "branch_pushed", to: "pr_create_intent",
              attributes: { "pr_create_intent_id" => Hive::DraftPrReceipt.mutation_id },
              worktree_root: root
            )
          when "pr_create_intent"
            receipt = reconcile_or_create_pr!(
              task, context, receipt, projected, root, cfg
            )
          when "pr_observed"
            verify_observed_pr!(context, receipt, cfg)
            write_pr_metadata!(task, receipt)
            receipt = terminal!(task, receipt, root, outcome: "pr-opened")
            secure_marker_set(
              File.join(task.folder, "fix-report.md"), :complete,
              outcome: "pr-opened", pr_url: receipt.fetch("pr_url")
            )
            return {
              commit: "pr_opened", status: :complete, outcome: "pr-opened",
              pr_url: receipt.fetch("pr_url")
            }
          when "terminal"
            return terminal_result(receipt)
          else
            raise IdentityError, "handoff phase #{receipt.fetch('phase').inspect} is not publishable"
          end
        end
      end
      private_class_method :publish!

      def record_agent_validation!(task, receipt, report_source, repository_state, root)
        digest = ::Digest::SHA256.hexdigest(report_source)
        if receipt.fetch("phase") == "worktree_created"
          return Hive::DraftPrReceipt.advance!(
            task.folder, from: "worktree_created", to: "agent_validated",
            attributes: {
              "head_oid" => repository_state.head_oid,
              "report_sha256" => digest
            },
            worktree_root: root
          )
        end
        if receipt["head_oid"] && receipt["head_oid"] != repository_state.head_oid
          raise IdentityError, "worktree HEAD changed after agent validation"
        end
        if receipt["report_sha256"] && receipt["report_sha256"] != digest
          raise IdentityError, "fix-report.md changed after agent validation"
        end

        receipt
      end
      private_class_method :record_agent_validation!

      def reconcile_or_push!(task, context, receipt, root, cfg)
        assert_local_identity!(context, receipt.fetch("head_oid"))
        preflight_remote!(context, cfg)
        reconcile_prs!(context, receipt, cfg, allow_owned: false)
        remote_oid = Hive::Gh.remote_branch_oid(
          context.worktree_path, context.task_branch, cfg: cfg
        )
        if remote_oid == receipt.fetch("head_oid")
          unless receipt["push_attempted_at"]
            raise IdentityError, "task branch exists remotely without a recorded push attempt"
          end
          return record_branch_pushed!(task, receipt, root)
        end
        raise IdentityError, "remote task branch moved to unfamiliar work" if remote_oid
        if receipt["push_attempted_at"]
          raise RecoverableError,
                "the recorded push attempt is not visible remotely; inspect before retrying"
        end

        receipt = Hive::DraftPrReceipt.update!(
          task.folder, phase: "push_intent",
          attributes: { "push_attempted_at" => Hive::DraftPrReceipt.timestamp },
          worktree_root: root
        )
        result = Hive::Gh.push_exact_oid(
          context.worktree_path, receipt.fetch("head_oid"), context.task_branch,
          cfg: cfg
        )
        observed = Hive::Gh.remote_branch_oid(
          context.worktree_path, context.task_branch, cfg: cfg
        )
        return record_branch_pushed!(task, receipt, root) if observed == receipt.fetch("head_oid")

        detail = result.success? ? "exact remote OID was not observable" : "ordinary non-force push failed"
        raise RecoverableError, detail
      end
      private_class_method :reconcile_or_push!

      def record_branch_pushed!(task, receipt, root)
        Hive::DraftPrReceipt.advance!(
          task.folder, from: "push_intent", to: "branch_pushed",
          attributes: {
            "observed_remote_oid" => receipt.fetch("head_oid"),
            "pushed_at" => Hive::DraftPrReceipt.timestamp
          },
          worktree_root: root
        )
      end
      private_class_method :record_branch_pushed!

      def reconcile_or_create_pr!(task, context, receipt, projected, root, cfg)
        assert_local_identity!(context, receipt.fetch("head_oid"))
        preflight_remote!(context, cfg)
        assert_remote_head!(context, receipt, cfg)
        prs = reconcile_prs!(context, receipt, cfg, allow_owned: true)
        return record_pr_observed!(task, receipt, prs.first, root) if prs.one?
        if receipt["pr_create_attempted_at"]
          raise RecoverableError,
                "the recorded PR creation attempt is not visible; inspect before retrying"
        end

        receipt = Hive::DraftPrReceipt.update!(
          task.folder, phase: "pr_create_intent",
          attributes: { "pr_create_attempted_at" => Hive::DraftPrReceipt.timestamp },
          worktree_root: root
        )
        repo = context.repository.sub(%r{\Agithub\.com/}, "")
        _out, _err, _status = Hive::Gh.create_draft_pr(
          context.worktree_path,
          repository: repo, host: "github.com", head: context.task_branch,
          base: context.base_branch, title: projected.title, body: projected.body,
          cfg: cfg
        )
        # The create response is never authoritative. A success, failure, or
        # malformed stdout all take the same bounded read-only reconciliation.
        prs = reconcile_prs!(context, receipt, cfg, allow_owned: true)
        return record_pr_observed!(task, receipt, prs.first, root) if prs.one?

        raise RecoverableError, "draft PR creation could not be reconciled"
      rescue Hive::GhError => e
        # Ambiguous transport errors may happen after GitHub accepted the
        # create. Perform exactly one read-only reconciliation before parking.
        prs = reconcile_prs!(context, receipt, cfg, allow_owned: true)
        return record_pr_observed!(task, receipt, prs.first, root) if prs.one?

        raise RecoverableError, "draft PR creation could not be reconciled"
      end
      private_class_method :reconcile_or_create_pr!

      def record_pr_observed!(task, receipt, pr, root)
        validated = validate_pr!(pr, receipt)
        Hive::DraftPrReceipt.advance!(
          task.folder, from: "pr_create_intent", to: "pr_observed",
          attributes: {
            "pr_number" => validated.fetch("number"),
            "pr_url" => validated.fetch("url"),
            "pr_state" => "OPEN",
            "observed_at" => Hive::DraftPrReceipt.timestamp
          },
          worktree_root: root
        )
      end
      private_class_method :record_pr_observed!

      def reconcile_prs!(context, receipt, cfg, allow_owned:)
        repo = context.repository.sub(%r{\Agithub\.com/}, "")
        prs = Hive::Gh.lookup_prs_for_branch(
          context.worktree_path, context.task_branch,
          repository: repo, host: "github.com", cfg: cfg
        )
        raise IdentityError, "multiple pull requests exist for the task branch" if prs.length > 1
        return [] if prs.empty?
        unless allow_owned && receipt["pr_create_intent_id"]
          raise IdentityError, "pull request exists without a controller mutation intent"
        end
        validate_pr!(prs.first, receipt)
        prs
      end
      private_class_method :reconcile_prs!

      def validate_pr!(pr, receipt)
        raise IdentityError, "pull-request lookup returned malformed data" unless pr.is_a?(Hash)
        state = pr["state"].to_s.upcase
        raise IdentityError, "pull request is closed or merged" unless state == "OPEN"
        expected_repo = receipt.fetch("repository").sub(%r{\Agithub\.com/}, "").downcase
        observed_repo = case pr["headRepository"]
        when Hash
          pr["headRepository"]["nameWithOwner"] || pr["headRepository"]["nameWithOwner".to_sym]
        else
          pr["headRepository"]
        end.to_s.sub(/\.git\z/i, "").downcase
        mismatches = []
        mismatches << "repository" unless observed_repo == expected_repo
        mismatches << "head branch" unless pr["headRefName"].to_s == receipt.fetch("task_branch")
        mismatches << "head OID" unless pr["headRefOid"].to_s.downcase == receipt.fetch("head_oid")
        mismatches << "base branch" unless pr["baseRefName"].to_s == receipt.fetch("base_branch")
        mismatches << "base OID" unless pr["baseRefOid"].to_s.downcase == receipt.fetch("base_oid")
        raise IdentityError, "pull request identity mismatch: #{mismatches.join(', ')}" unless mismatches.empty?

        number = Integer(pr["number"].to_s, 10)
        url = pr["url"].to_s
        expected_url = "https://github.com/#{expected_repo}/pull/#{number}"
        raise IdentityError, "pull request URL is outside the recorded repository" unless url == expected_url

        { "number" => number, "url" => url }
      rescue ArgumentError, TypeError
        raise IdentityError, "pull request number is invalid"
      end
      private_class_method :validate_pr!

      def verify_observed_pr!(context, receipt, cfg)
        preflight_remote!(context, cfg)
        assert_local_identity!(context, receipt.fetch("head_oid"))
        assert_remote_head!(context, receipt, cfg)
        prs = reconcile_prs!(context, receipt, cfg, allow_owned: true)
        raise IdentityError, "observed pull request is no longer uniquely visible" unless prs.one?
        validated = validate_pr!(prs.first, receipt)
        unless validated["number"] == receipt.fetch("pr_number") &&
               validated["url"] == receipt.fetch("pr_url")
          raise IdentityError, "observed pull request changed identity"
        end
      end
      private_class_method :verify_observed_pr!

      def assert_remote_unowned!(context, receipt, cfg)
        remote = Hive::Gh.remote_branch_oid(context.worktree_path, context.task_branch, cfg: cfg)
        raise IdentityError, "task branch already exists remotely without controller intent" if remote
        reconcile_prs!(context, receipt, cfg, allow_owned: false)
      end
      private_class_method :assert_remote_unowned!

      def assert_remote_head!(context, receipt, cfg)
        remote = Hive::Gh.remote_branch_oid(context.worktree_path, context.task_branch, cfg: cfg)
        return if remote == receipt.fetch("head_oid")

        raise IdentityError, "remote task branch no longer matches the scanned head"
      end
      private_class_method :assert_remote_head!

      def preflight_remote!(context, cfg)
        begin
          Hive::Gh.ensure_authenticated!(cfg, host: "github.com")
        rescue Hive::GhError
          raise RecoverableError, "GitHub authentication is unavailable for draft-PR handoff"
        end
        identity = Hive::Gh.repository_identity(context.worktree_path, cfg: cfg)
        observed = "#{identity.fetch('host').downcase}/#{identity.fetch('repository').downcase}"
        raise IdentityError, "origin push repository changed after agent execution" unless observed == context.repository

        fetch_out, fetch_err, fetch_status = Hive::Gh.capture3(
          "git", "-C", context.worktree_path, "remote", "get-url", "--all", "origin", cfg: cfg
        )
        raise IdentityError, "origin fetch repository is unavailable" unless fetch_status.success?
        urls = fetch_out.lines.map(&:strip).reject(&:empty?)
        raise IdentityError, "origin fetch repository is ambiguous" unless urls.one?
        fetch_identity = Hive::Gh.repository_identity_from_remote(urls.first)
        fetch_repo = "#{fetch_identity.fetch('host').downcase}/#{fetch_identity.fetch('repository').downcase}"
        raise IdentityError, "origin fetch repository changed after agent execution" unless fetch_repo == context.repository

        begin
          base = Hive::Gh.remote_branch_oid(context.worktree_path, context.base_branch, cfg: cfg)
        rescue Hive::GhError
          raise RecoverableError, "recorded base branch could not be observed remotely"
        end
        raise IdentityError, "recorded base branch moved during repair" unless base == context.base_oid
      rescue KeyError, Hive::GhError => e
        raise IdentityError, "remote identity preflight failed: #{e.class}"
      end
      private_class_method :preflight_remote!

      def assert_local_identity!(context, expected_head)
        branch = git!(context.worktree_path, "symbolic-ref", "--quiet", "--short", "HEAD").strip
        raise IdentityError, "worktree branch changed after agent validation" unless branch == context.task_branch
        head = git!(context.worktree_path, "rev-parse", "HEAD").strip.downcase
        raise IdentityError, "worktree HEAD changed after publication scan" unless head == expected_head
        status = git!(context.worktree_path, "status", "--porcelain=v1", "--untracked-files=all")
        raise IdentityError, "worktree became dirty after agent validation" unless status.empty?
        _out, _err, ancestry = Open3.capture3(
          "git", "-C", context.worktree_path, "merge-base", "--is-ancestor", context.base_oid, head
        )
        raise IdentityError, "worktree head is no longer descended from recorded base" unless ancestry.success?
      end
      private_class_method :assert_local_identity!

      def project_report(report)
        fields = {
          "Reproduction" => report.reproduction,
          "Cause" => report.cause,
          "Changes" => report.changes,
          "Tests" => report.tests,
          "Risks" => report.risks
        }.transform_values { |value| safe_summary(value) }
        title = safe_summary(report.suggested_pr_title, max: MAX_PR_TITLE_CHARS, single_line: true)
        body = fields.map { |label, value| "## #{label}\n#{value}" }.join("\n\n")
        body = body[0, MAX_PR_BODY_CHARS]
        scan_text!(title, source: "PR title")
        scan_text!(body, source: "PR body")
        Result.new(title: title, body: body)
      end
      private_class_method :project_report

      def safe_summary(value, max: MAX_SUMMARY_CHARS, single_line: false)
        text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
        text = text.gsub(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/, "[redacted email]")
        text = text.gsub(%r{(?:/home|/Users|/tmp|/private/tmp|/var/folders)/[^\s)`'\"]+}, "[redacted local path]")
        text = text.gsub(/[A-Za-z]:\\[^\s)`'\"]+/, "[redacted local path]")
        text = text.gsub(%r{(?:https?|file)://[^\s)`'\"]+}, "[redacted URL]")
        text = text.gsub(/[\r\n\t ]+/, single_line ? " " : " ").strip
        text = text[0, max].to_s.strip
        raise QuarantineError, "report evidence cannot be summarized safely" if text.empty?

        text
      end
      private_class_method :safe_summary

      def scan_publication!(context, head_oid, report_source, projected)
        digest = ::Digest::SHA256.new
        scanned_bytes = 0
        add_piece = lambda do |piece, source|
          scanned_bytes += piece.bytesize
          if scanned_bytes > MAX_SCAN_BYTES
            raise QuarantineError, "publication scan exceeds #{MAX_SCAN_BYTES} bytes at #{source}"
          end
          digest << ::Digest::SHA256.digest(piece)
        end
        scan_text!(report_source, source: "repair report")
        add_piece.call(report_source, "repair report")
        add_piece.call(projected.title, "PR title")
        add_piece.call(projected.body, "PR body")
        commits = git_binary!(
          context.worktree_path, "rev-list", "--reverse", "#{context.base_oid}..#{head_oid}",
          max_bytes: MAX_OBJECT_LIST_BYTES
        )
                  .lines.map(&:strip).reject(&:empty?)
        raise IdentityError, "validated repair has no commits" if commits.empty?
        if commits.length > MAX_COMMITS
          raise QuarantineError, "repair history exceeds #{MAX_COMMITS} commits"
        end
        commits.each do |oid|
          object_size = git!(context.worktree_path, "cat-file", "-s", oid).to_i
          reject_oversized_object!(object_size, "commit object")
          commit = git_binary!(
            context.worktree_path, "cat-file", "-p", oid,
            max_bytes: MAX_OBJECT_BYTES
          )
          scan_blob!(commit, source: "commit object")
          diff = git_binary!(
            context.worktree_path, "show", "--format=fuller", "--no-ext-diff",
            "--no-renames", "--no-textconv", "--binary", oid,
            max_bytes: MAX_DIFF_BYTES
          )
          scan_blob!(diff, source: "commit diff")
          add_piece.call(commit, "commit object")
          add_piece.call(diff, "commit diff")
        end

        objects = git_binary!(
          context.worktree_path, "rev-list", "--objects", "#{context.base_oid}..#{head_oid}",
          max_bytes: MAX_OBJECT_LIST_BYTES
        ).lines
        raise QuarantineError, "repair history exceeds #{MAX_OBJECTS} objects" if objects.length > MAX_OBJECTS
        objects.each do |line|
          oid = line.split(" ", 2).first.to_s
          type = git!(context.worktree_path, "cat-file", "-t", oid).strip
          next unless type == "blob"

          object_size = git!(context.worktree_path, "cat-file", "-s", oid).to_i
          reject_oversized_object!(object_size, "reachable commit blob")
          blob = git_binary!(
            context.worktree_path, "cat-file", "-p", oid,
            max_bytes: MAX_OBJECT_BYTES
          )
          scan_blob!(blob, source: "reachable commit blob")
          add_piece.call(blob, "reachable commit blob")
        end

        final_paths = git_binary!(
          context.worktree_path, "diff", "--name-only", "--diff-filter=ACMRT", "-z",
          context.base_oid, head_oid, max_bytes: MAX_PATH_LIST_BYTES
        ).split("\0").reject(&:empty?)
        final_paths.each do |path|
          object_size = git!(context.worktree_path, "cat-file", "-s", "#{head_oid}:#{path}").to_i
          reject_oversized_object!(object_size, "final changed file")
          content = git_binary!(
            context.worktree_path, "show", "#{head_oid}:#{path}",
            max_bytes: MAX_OBJECT_BYTES
          )
          scan_blob!(content, source: "final changed file")
          add_piece.call(content, "final changed file")
        end
        digest.hexdigest
      end
      private_class_method :scan_publication!

      def reject_oversized_object!(size, source)
        if size.negative? || size > MAX_OBJECT_BYTES
          raise QuarantineError, "#{source} exceeds #{MAX_OBJECT_BYTES} bytes"
        end
      end
      private_class_method :reject_oversized_object!

      def scan_blob!(content, source:)
        bytes = content.to_s.b
        if bytes.include?("\0") || !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise QuarantineError, "#{source} contains unsupported binary content"
        end
        if bytes.start_with?("version https://git-lfs.github.com/spec/v1") ||
           bytes.include?("GIT binary patch") || bytes.include?("Binary files ")
          raise QuarantineError, "#{source} contains unsupported binary or LFS content"
        end
        scan_text!(bytes.force_encoding(Encoding::UTF_8), source: source)
      end
      private_class_method :scan_blob!

      def scan_text!(text, source:)
        hits = Hive::SecretPatterns.scan(text.to_s)
        raise QuarantineError, "#{source} contains prohibited credential material" unless hits.empty?
      end
      private_class_method :scan_text!

      def terminal!(task, receipt, root, outcome:, error_reason: nil)
        return receipt if receipt.fetch("phase") == "terminal"
        attributes = {
          "terminal_outcome" => outcome,
          "terminal_at" => Hive::DraftPrReceipt.timestamp
        }
        attributes["error_reason"] = error_reason if error_reason
        terminal = Hive::DraftPrReceipt.advance!(
          task.folder, from: receipt.fetch("phase"), to: "terminal",
          attributes: attributes, worktree_root: root
        )
        if outcome == "no-fix"
          secure_marker_set(File.join(task.folder, "fix-report.md"), :complete, outcome: "no-fix")
        end
        terminal
      end
      private_class_method :terminal!

      def terminal_result(receipt)
        case receipt.fetch("terminal_outcome")
        when "pr-opened"
          { commit: nil, status: :complete, outcome: "pr-opened", pr_url: receipt.fetch("pr_url") }
        when "no-fix"
          { commit: nil, status: :complete, outcome: "no-fix" }
        else
          { commit: nil, status: :error, outcome: "blocked" }
        end
      end
      private_class_method :terminal_result

      def cleanup_no_fix_worktree(task, context)
        Hive::Worktree.new(task.project_root, task.slug).remove!(path: context.worktree_path)
      rescue Hive::WorktreeError => e
        warn "hive: clean no-fix worktree cleanup deferred (#{e.class})"
      end
      private_class_method :cleanup_no_fix_worktree

      def ensure_terminal_artifacts!(task, receipt)
        path = File.join(task.folder, "fix-report.md")
        case receipt.fetch("terminal_outcome")
        when "pr-opened"
          write_pr_metadata!(task, receipt)
          marker = Hive::Markers.current(path)
          unless marker.name == :complete && marker.attrs["outcome"] == "pr-opened" &&
                 marker.attrs["pr_url"] == receipt.fetch("pr_url")
            secure_marker_set(path, :complete, outcome: "pr-opened", pr_url: receipt.fetch("pr_url"))
          end
        when "no-fix"
          marker = Hive::Markers.current(path)
          secure_marker_set(path, :complete, outcome: "no-fix") unless
            marker.name == :complete && marker.attrs["outcome"] == "no-fix"
        when "blocked"
          reason = receipt["error_reason"] || IDENTITY_REASON
          marker = Hive::Markers.current(path)
          marker_error!(task, reason, "Draft-PR handoff is blocked; inspect preserved local state.") unless
            marker.name == :error && marker.attrs["reason"] == reason
        end
      end
      private_class_method :ensure_terminal_artifacts!

      def quarantine!(task, context, error)
        root = File.dirname(context.worktree_path)
        receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: root)
        terminal!(task, receipt, root, outcome: "blocked", error_reason: QUARANTINE_REASON)
        redact_quarantined_report!(task)
        marker_error!(
          task, QUARANTINE_REASON,
          "Publication blocked by prohibited local content. Inspect and securely clean the isolated worktree; Hive will not publish or auto-retry it."
        )
        { commit: "quarantined", status: :error, outcome: "blocked", error: error.class.name }
      end
      private_class_method :quarantine!

      def redact_quarantined_report!(task)
        path = File.join(task.folder, "fix-report.md")
        source = File.open(path, File::RDONLY | File::NOFOLLOW, encoding: "UTF-8") do |file|
          raise IOError, "fix-report.md is not regular" unless file.stat.file?

          file.read(Hive::Stages::AgentReport::MAX_BYTES + 1)
        end
        redacted = Hive::SecretPatterns.redact(source)
        redacted = redacted.gsub(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/, "[redacted email]")
        redacted = redacted.gsub(%r{(?:/home|/Users|/tmp|/private/tmp|/var/folders)/[^\s)`'\"]+}, "[redacted local path]")
        redacted = redacted.gsub(/[A-Za-z]:\\[^\s)`'\"]+/, "[redacted local path]")
        redacted = redacted.gsub(%r{(?:https?|file)://[^\s)`'\"]+}, "[redacted URL]")
        Hive::AtomicFile.write(path, redacted, mode: 0o600)
      rescue SystemCallError, IOError
        # Marker text remains redacted even when the untrusted report cannot be
        # rewritten; the quarantined worktree is never published or auto-run.
        nil
      end
      private_class_method :redact_quarantined_report!

      def block_identity!(task, context, error)
        root = File.dirname(context.worktree_path)
        receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: root)
        terminal!(task, receipt, root, outcome: "blocked", error_reason: IDENTITY_REASON)
        marker_error!(
          task, IDENTITY_REASON,
          "Draft-PR identity validation blocked publication. Preserve the worktree and inspect remote state manually."
        )
        { commit: "identity_blocked", status: :error, outcome: "blocked", error: error.class.name }
      end
      private_class_method :block_identity!

      def recoverable!(task, error)
        secure_marker_set(
          File.join(task.folder, "fix-report.md"), :error,
          reason: RECOVERABLE_REASON,
          retry: "hive run #{task.slug}",
          message: "Validated local work is preserved; remote handoff needs a manual retry."
        )
        { commit: "handoff_recoverable", status: :error, outcome: "blocked", error: error.class.name }
      end
      private_class_method :recoverable!

      def marker_error!(task, reason, message)
        secure_marker_set(
          File.join(task.folder, "fix-report.md"), :error,
          reason: reason, outcome: "blocked", message: message
        )
      end
      private_class_method :marker_error!

      def secure_marker_set(path, name, attrs = {})
        marker = Hive::Markers.set(path, name, attrs)
        File.chmod(0o600, path)
        marker
      end
      private_class_method :secure_marker_set

      def write_pr_metadata!(task, receipt)
        body = <<~MD
          ---
          pr_url: #{receipt.fetch("pr_url")}
          pr_number: #{receipt.fetch("pr_number")}
          ---

          ## Summary
          Verified draft PR opened by Hive's managed handoff.
        MD
        Hive::AtomicFile.write(File.join(task.folder, "pr.md"), body, mode: 0o600)
      end
      private_class_method :write_pr_metadata!

      def git!(path, *args)
        out, err, status = Open3.capture3("git", "-C", path, *args)
        return out if status.success?

        detail = err.to_s.strip
        detail = out.to_s.strip if detail.empty?
        raise IdentityError, "git #{args.first} failed during handoff: #{detail[0, 200]}"
      end
      private_class_method :git!

      def git_binary!(path, *args, max_bytes: nil)
        out, err, status = Open3.capture3("git", "-C", path, *args, binmode: true)
        if status.success?
          if max_bytes && out.bytesize > max_bytes
            raise QuarantineError, "git #{args.first} output exceeds #{max_bytes} bytes"
          end
          return out
        end

        detail = err.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").strip
        raise IdentityError, "git #{args.first} failed during publication scan: #{detail[0, 200]}"
      end
      private_class_method :git_binary!
    end
  end
end
