require "fileutils"
require "hive/git_ops"

module Hive
  module RefactorPatrol
    # Validates and pins the registered default-branch checkout without ever
    # fetching or repairing it. A held Snapshot owns the nonblocking lock for
    # the complete child lifetime.
    class CheckoutGuard
      SENTINELS = %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply].freeze

      class Blocked < Hive::Error
        attr_reader :reason, :evidence

        def initialize(reason, message, evidence: {})
          super(message)
          @reason = reason
          @evidence = evidence
        end

        def exit_code
          Hive::ExitCodes::TEMPFAIL
        end
      end

      class Snapshot
        attr_reader :root_realpath, :branch, :default_branch, :head_sha

        def initialize(root_realpath:, branch:, default_branch:, head_sha:, lock_io:)
          @root_realpath = root_realpath
          @branch = branch
          @default_branch = default_branch
          @head_sha = head_sha
          @lock_io = lock_io
        end

        def release
          return if @lock_io.nil? || @lock_io.closed?

          @lock_io.flock(File::LOCK_UN)
          @lock_io.close
        end
      end

      def initialize(project_root, default_branch: nil, git: nil)
        @project_root = File.expand_path(project_root)
        @git = git || Hive::GitOps.new(@project_root)
        @default_branch = default_branch
      end

      def acquire!
        root = validate_root!
        branch, default_branch, head = validate_checkout!
        lock = acquire_lock!
        Snapshot.new(
          root_realpath: root,
          branch: branch,
          default_branch: default_branch,
          head_sha: head,
          lock_io: lock
        )
      rescue Blocked
        lock&.close unless lock&.closed?
        raise
      rescue Hive::GitError, SystemCallError => e
        lock&.close unless lock&.closed?
        raise Blocked.new("checkout_unavailable", "registered trunk cannot be inspected", evidence: { "error" => e.message })
      end

      def assert_unchanged!(snapshot)
        root = validate_root!
        branch, default_branch, head = validate_checkout!
        unless root == snapshot.root_realpath && branch == snapshot.branch &&
               default_branch == snapshot.default_branch && head == snapshot.head_sha
          raise Blocked.new(
            "checkout_moved",
            "registered trunk changed during architecture analysis",
            evidence: { "expected_head" => snapshot.head_sha, "actual_head" => head,
                        "expected_branch" => snapshot.branch, "actual_branch" => branch }
          )
        end

        true
      end

      private

      def validate_root!
        unless File.directory?(@project_root)
          raise Blocked.new("checkout_missing", "registered trunk path is missing")
        end

        File.realpath(@project_root)
      rescue Errno::ENOENT
        raise Blocked.new("checkout_missing", "registered trunk path is missing")
      end

      def validate_checkout!
        operation = SENTINELS.find { |name| File.exist?(@git.git_path(name)) }
        if operation
          raise Blocked.new("checkout_operation_in_progress", "registered trunk has an in-progress Git operation",
                            evidence: { "sentinel" => operation })
        end

        branch = @git.current_branch
        raise Blocked.new("checkout_detached", "registered trunk is detached") unless branch

        default_branch = @default_branch || @git.detect_default_branch
        unless branch == default_branch
          raise Blocked.new("checkout_wrong_branch", "registered trunk is not on its default branch",
                            evidence: { "expected" => default_branch, "actual" => branch })
        end

        dirty = @git.status_short_excluding_hive_state
        unless dirty.empty?
          raise Blocked.new("checkout_dirty", "registered trunk has tracked or untracked changes",
                            evidence: { "status" => dirty.byteslice(0, 1_000) })
        end

        head = @git.head_sha
        local = @git.rev_parse("refs/heads/#{default_branch}")
        unless head == local
          raise Blocked.new("checkout_stale", "registered trunk HEAD does not match its local branch ref",
                            evidence: { "head" => head, "local" => local })
        end

        validate_cached_origin!(default_branch, head)
        [ branch, default_branch, head ]
      end

      def validate_cached_origin!(branch, head)
        return unless @git.remotes.include?("origin")

        remote_ref = "refs/remotes/origin/#{branch}"
        unless @git.ref_exists?(remote_ref)
          raise Blocked.new("checkout_stale", "registered trunk has no cached origin branch ref",
                            evidence: { "remote_ref" => remote_ref })
        end

        remote = @git.rev_parse(remote_ref)
        return if remote == head

        raise Blocked.new("checkout_stale", "registered trunk differs from its cached origin branch ref",
                          evidence: { "head" => head, "remote" => remote })
      end

      def acquire_lock!
        path = File.join(@project_root, ".hive-state", "refactor_patrol", "post_merge", "architecture.lock")
        FileUtils.mkdir_p(File.dirname(path))
        lock = File.open(path, File::RDWR | File::CREAT, 0o644)
        return lock if lock.flock(File::LOCK_EX | File::LOCK_NB)

        lock.close
        raise Blocked.new("checkout_busy", "registered trunk architecture lock is held",
                          evidence: { "lock_path" => path })
      end
    end
  end
end
