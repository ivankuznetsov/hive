require "hive/config"
require "hive/draft_pr_receipt"
require "hive/gh"
require "hive/worktree"
require "open3"

module Hive
  module Stages
    # Controller-owned setup for the closed workspace:worktree +
    # handoff:draft_pr stage contract. U3 consumes Context to run and validate
    # the mapped agent; U4 advances the receipt through remote handoff phases.
    module AgentWorktree
      module_function

      Context = Data.define(
        :worktree_path, :task_branch, :base_branch, :base_oid, :repository
      )

      def run!(task, cfg)
        context = prepare!(task, cfg)
        {
          commit: "worktree_initialized",
          status: :worktree_ready,
          worktree_context: context
        }
      end

      def prepare!(task, cfg)
        if task.depends_on
          raise Hive::WorktreeError,
                "draft-PR worktree tasks do not support depends_on stacking"
        end

        base_branch = Hive::Worktree.validate_branch_name!(task.base_branch)
        repository = controller_repository!(task.project_root, cfg)
        fetch_repository = controller_fetch_repository!(task.project_root, cfg)
        unless fetch_repository == repository
          raise Hive::WorktreeError,
                "origin fetch repository #{fetch_repository} does not match push repository #{repository}"
        end
        Hive::Gh.ensure_authenticated!(cfg, host: "github.com")

        worktree = Hive::Worktree.new(task.project_root, task.slug)
        root = worktree.worktree_root
        pointer_path = File.join(task.folder, "worktree.yml")
        receipt_path = Hive::DraftPrReceipt.path(task.folder)
        pointer_exists = File.exist?(pointer_path) || File.symlink?(pointer_path)
        receipt_exists = File.exist?(receipt_path) || File.symlink?(receipt_path)
        if pointer_exists != receipt_exists
          raise Hive::WorktreeError,
                "draft-PR worktree state is incomplete; preserving pointer, receipt, branch, and worktree"
        end

        # Exact remote availability is preflighted on every run. A later base
        # advance does not rewrite the saved baseline: resumes validate the
        # recorded OID's ancestry instead.
        observed_base_oid = worktree.fetch_strict_origin_base!(base_branch)
        if pointer_exists
          resume_context!(
            task, cfg, worktree, root,
            base_branch: base_branch, repository: repository
          )
        else
          create_context!(
            task, worktree, root,
            base_branch: base_branch, base_oid: observed_base_oid,
            repository: repository
          )
        end
      end

      def controller_repository!(path, cfg)
        identity = Hive::Gh.repository_identity(path, cfg: cfg)
        host = identity.fetch("host").to_s.downcase
        raise Hive::WorktreeError, "draft-PR handoff supports github.com repositories only" unless host == "github.com"

        "#{host}/#{identity.fetch('repository').to_s.downcase}"
      rescue KeyError => e
        raise Hive::WorktreeError, "could not resolve canonical origin repository: #{e.message}"
      end
      private_class_method :controller_repository!

      def controller_fetch_repository!(path, cfg)
        out, err, status = Hive::Gh.capture3(
          "git", "-C", path, "remote", "get-url", "--all", "origin", cfg: cfg
        )
        unless status.success?
          raise Hive::WorktreeError,
                "could not read origin fetch URL: #{err.to_s.strip.empty? ? out : err}"
        end
        urls = out.lines.map(&:strip).reject(&:empty?)
        unless urls.one?
          raise Hive::WorktreeError, "origin fetch URL lookup returned #{urls.length} records; expected exactly one"
        end
        identity = Hive::Gh.repository_identity_from_remote(urls.first)
        host = identity.fetch("host").to_s.downcase
        raise Hive::WorktreeError, "draft-PR handoff supports github.com repositories only" unless host == "github.com"

        "#{host}/#{identity.fetch('repository').to_s.downcase}"
      rescue Hive::GhError, KeyError => e
        raise Hive::WorktreeError, "could not resolve canonical origin fetch repository: #{e.message}"
      end
      private_class_method :controller_fetch_repository!

      def create_context!(task, worktree, root, base_branch:, base_oid:, repository:)
        worktree.create_strict_origin!(
          task.slug, base_branch: base_branch, base_oid: base_oid
        )
        pointer = {
          "path" => worktree.path,
          "branch" => task.slug,
          "base_branch" => base_branch,
          "base_oid" => base_oid,
          "repository" => repository
        }
        worktree.write_pointer!(
          task.folder, task.slug,
          base_branch: base_branch, base_oid: base_oid, repository: repository
        )
        receipt = receipt_from(pointer)
        Hive::DraftPrReceipt.initialize!(task.folder, expected: receipt, worktree_root: root)
        validate_repository_match!(worktree.path, repository)
        context_from(pointer)
      end
      private_class_method :create_context!

      def resume_context!(task, cfg, worktree, root, base_branch:, repository:)
        expected = {
          "path" => worktree.path,
          "branch" => task.slug,
          "base_branch" => base_branch,
          "repository" => repository
        }
        pointer = Hive::Worktree.read_strict_pointer(
          task.folder, expected_root: root, expected: expected
        )
        Hive::DraftPrReceipt.read(
          task.folder, expected: receipt_from(pointer), worktree_root: root
        )
        worktree.validate_strict_resume!(
          branch_name: task.slug, base_oid: pointer.fetch("base_oid")
        )
        validate_repository_match!(worktree.path, repository, cfg: cfg)
        context_from(pointer)
      end
      private_class_method :resume_context!

      def validate_repository_match!(worktree_path, expected, cfg: nil)
        actual = controller_repository!(worktree_path, cfg)
        return if actual == expected

        raise Hive::WorktreeError,
              "worktree repository #{actual} does not match recorded repository #{expected}"
      end
      private_class_method :validate_repository_match!

      def receipt_from(pointer)
        {
          "version" => Hive::DraftPrReceipt::VERSION,
          "phase" => Hive::DraftPrReceipt::INITIAL_PHASE,
          "repository" => pointer.fetch("repository"),
          "base_branch" => pointer.fetch("base_branch"),
          "base_oid" => pointer.fetch("base_oid"),
          "task_branch" => pointer.fetch("branch"),
          "worktree_path" => pointer.fetch("path")
        }
      end
      private_class_method :receipt_from

      def context_from(pointer)
        Context.new(
          worktree_path: pointer.fetch("path"),
          task_branch: pointer.fetch("branch"),
          base_branch: pointer.fetch("base_branch"),
          base_oid: pointer.fetch("base_oid"),
          repository: pointer.fetch("repository")
        )
      end
      private_class_method :context_from
    end
  end
end
