require "open3"
require "fileutils"
require "yaml"
require "hive/config"
require "hive/git_ops"

module Hive
  class Worktree
    NONINTERACTIVE_FETCH_ENV = {
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes -oConnectTimeout=10",
      # Bound HTTPS fetches too. The SSH options only cap the SSH connect;
      # on an HTTPS origin a stalled remote (dead TCP, hung proxy) makes
      # `git fetch` hang indefinitely, wedging the now-non-daemonized
      # 4-execute (freshest_override_base) and 5-open-pr
      # (origin_branch_exists?) stage paths this branch introduced. Abort
      # the transfer if it stays under ~1 KB/s for 30 contiguous seconds.
      "GIT_HTTP_LOW_SPEED_LIMIT" => "1000",
      "GIT_HTTP_LOW_SPEED_TIME" => "30"
    }.freeze
    FETCH_TIMEOUT_SEC = 60
    FetchStatus = Struct.new(:exitstatus, keyword_init: true) do
      def success?
        exitstatus.zero?
      end
    end

    attr_reader :project_root, :slug

    def initialize(project_root, slug, worktree_root: nil)
      @project_root = File.expand_path(project_root)
      @slug = slug
      @worktree_root = worktree_root && File.expand_path(worktree_root)
    end

    def path
      File.join(worktree_root, @slug)
    end

    def worktree_root
      return @worktree_root if @worktree_root

      cfg = Hive::Config.load(@project_root)
      template = cfg["worktree_root"] ||
                 self.class.default_worktree_root(File.basename(@project_root))
      File.expand_path(template)
    end

    def exists?
      return false unless File.directory?(path)

      list_worktree_paths.include?(path)
    end

    def create!(branch_name, default_branch:, base_override: nil)
      FileUtils.mkdir_p(File.dirname(path))

      _, _, exists = Open3.capture3("git", "-C", @project_root,
                                    "show-ref", "--verify", "refs/heads/#{branch_name}")
      reuse_existing = exists.success?
      stacked_override = !base_override.to_s.strip.empty?
      # Delete-then-recreate is intentionally non-atomic: if the `worktree add`
      # below fails after this delete, the placeholder branch is gone with no
      # rollback. This is safe ONLY because `empty_placeholder?` positively
      # proved the branch carries no unique commits (it sits at a default ref's
      # tip), so nothing recoverable is lost. A future loosening of that
      # emptiness gate would silently turn this into data loss — keep the proof
      # strictly ahead of the delete.
      if reuse_existing && stacked_override && empty_placeholder?(branch_name, default_branch)
        delete_local_branch!(branch_name)
        reuse_existing = false
      end

      if reuse_existing
        # A local branch named `branch_name` already exists. Attach it as-is
        # so committed work is never discarded by dependency stacking. Empty
        # placeholders are the only exception: with a stacked override they
        # are deleted above (see `empty_placeholder?`, which measures
        # emptiness against both `origin/<default>` and local `<default>` —
        # empty if no unique commits beyond either — never against the
        # override base) and recreated through the normal first-creation path
        # below.
        args = [ "worktree", "add", path, branch_name ]
      else
        # Branch new worktrees from `origin/<default>` (after a quick
        # fetch) instead of local `<default>` so a stale or
        # behind-origin local default doesn't silently produce a
        # worktree missing the latest upstream commits. Auto-rebase
        # (PR #69) handles drift in long-running worktrees; this
        # handles drift at creation time. Fail-soft: if there is no
        # `origin` remote, or the fetch fails (network down, auth),
        # fall back to the local default with a stderr warning.
        # Never touches local `<default>` — preserves any unpushed
        # commits the user has there.
        base = if stacked_override
                 freshest_override_base(base_override, default_branch)
        else
                 freshest_base(default_branch)
        end
        args = [ "worktree", "add", path, "-b", branch_name, base ]
      end
      out, err, status = Open3.capture3("git", "-C", @project_root, *args)
      unless status.success?
        raise WorktreeError, "git worktree add failed: #{err.strip.empty? ? out : err}"
      end

      :created
    end

    # Create a deterministic branch from one exact, already-present commit.
    # Unlike create!, this path performs no fetch and has no fallback to a
    # moving branch name; architecture patrol uses it to preserve the analysis
    # snapshot while keeping the registered checkout untouched.
    def create_exact!(branch_name, base_sha:)
      FileUtils.mkdir_p(File.dirname(path))
      expected = self.class.run_materialize_git!(
        @project_root, "rev-parse", "--verify", "#{base_sha}^{commit}"
      ).strip

      if exists?
        checked_out = self.class.run_materialize_git!(path, "branch", "--show-current").strip
        raise WorktreeError, "worktree #{path} is not on branch #{branch_name}" unless checked_out == branch_name

        assert_exact_branch_base!(branch_name, expected)
        return :existing
      end

      _, _, branch_exists = Open3.capture3(
        "git", "-C", @project_root, "show-ref", "--verify", "refs/heads/#{branch_name}"
      )
      args = if branch_exists.success?
               assert_exact_branch_base!(branch_name, expected)
               [ "worktree", "add", path, branch_name ]
      else
               [ "worktree", "add", path, "-b", branch_name, expected ]
      end
      self.class.run_materialize_git!(@project_root, *args)
      :created
    end

    def remove!(path: self.path, force: false)
      args = [ "worktree", "remove" ]
      args << "--force" if force
      args << path
      out, err, status = Open3.capture3("git", "-C", @project_root, *args)
      raise WorktreeError, "git worktree remove failed: #{err.strip.empty? ? out : err}" unless status.success?

      :removed
    end

    # Fallback used by drop when `git worktree remove` refuses (locked,
    # dirty tree, missing index). `--force` will discard uncommitted
    # work in the worktree, so callers must already have decided the
    # data is forfeit (drop is irreversible by contract).
    def remove_force!(path: self.path)
      remove!(path: path, force: true)
    end

    # Decide what to base a new worktree branch on. Prefer
    # `origin/<default>` after a quick fetch so the worktree starts
    # at upstream's current tip. Fall back to local `<default>` on:
    #   - no `origin` remote configured (early-stage repos, forks
    #     without an upstream)
    #   - fetch failure (network down, auth missing, dead remote)
    # The fetch uses the same non-interactive env as
    # `GitOps#fetch_default_branch` (PR #69) so credential prompts
    # cannot hang the worktree-creation path.
    def freshest_base(default_branch)
      return default_branch unless self.class.origin_configured?(@project_root)

      _, err, status = self.class.fetch_origin_branch(@project_root, default_branch)
      unless status.success?
        warn "[hive] worktree base: fetch origin #{default_branch} failed " \
             "(#{err.strip[0, 200]}); branching from local #{default_branch}"
        return default_branch
      end

      "origin/#{default_branch}"
    end

    def freshest_override_base(base_override, default_branch)
      branch = base_override.to_s.strip
      return freshest_base(default_branch) if branch.empty?

      unless self.class.origin_configured?(@project_root)
        # No origin remote, so the requested stacked base can't be fetched.
        # Warn like the sibling branches below so a dropped stack request is
        # observable instead of silently collapsing onto the default.
        return override_local_or_default(
          branch, default_branch,
          "no origin remote, origin/#{branch} unavailable"
        )
      end

      _, err, status = self.class.fetch_origin_branch(@project_root, branch)
      unless status.success?
        return override_local_or_default(
          branch, default_branch,
          "fetch origin #{branch} failed (#{err.strip[0, 200]})"
        )
      end

      unless self.class.origin_branch_ref_exists?(@project_root, branch)
        return override_local_or_default(
          branch, default_branch,
          "origin/#{branch} not found after fetch"
        )
      end

      "origin/#{branch}"
    end

    def list_worktree_paths
      out, _err, status = Open3.capture3("git", "-C", @project_root, "worktree", "list", "--porcelain")
      return [] unless status.success?

      out.split("\n").select { |l| l.start_with?("worktree ") }.map { |l| l.sub(/\Aworktree /, "").strip }
    end

    def write_pointer!(task_folder, branch_name, execute_base_head: nil)
      data = {
        "path" => path,
        "branch" => branch_name,
        "created_at" => Time.now.utc.iso8601
      }
      data["execute_base_head"] = execute_base_head if execute_base_head
      File.write(File.join(task_folder, "worktree.yml"), data.to_yaml)
    end

    def self.read_pointer(task_folder)
      pointer = File.join(task_folder, "worktree.yml")
      return nil unless File.exist?(pointer)

      data = begin
        YAML.safe_load(File.read(pointer))
      rescue Psych::Exception, SystemCallError, IOError
        nil
      end
      return nil if data.nil?

      raise WorktreeError, "worktree.yml must be a hash" unless data.is_a?(Hash)

      data
    end

    # Base dir under which per-project worktree roots live by default
    # (`<base>/<project>.worktrees`). Overridable via HIVE_WORKTREE_BASE so
    # tests (and relocated setups) never seed the developer's real ~/Dev.
    def self.worktree_base
      ENV["HIVE_WORKTREE_BASE"] || File.expand_path("~/Dev")
    end

    def self.default_worktree_root(project_name)
      File.join(worktree_base, "#{project_name}.worktrees")
    end

    # Resolves the canonical worktree root for a project (per-project
    # `worktree_root` override, falling back to `<HIVE_WORKTREE_BASE or
    # ~/Dev>/<repo>.worktrees`). Shared by Drop and other callers so the
    # resolution rule has one home; previously Drop duplicated the formula
    # and would have silently drifted on any future change here.
    def self.canonical_root(project_root)
      cfg = Hive::Config.load(project_root)
      File.expand_path(
        cfg["worktree_root"] ||
          default_worktree_root(File.basename(File.expand_path(project_root)))
      )
    end

    def self.origin_branch_exists?(project_root, branch_name)
      branch = branch_name.to_s.strip
      return false if branch.empty?
      return false unless origin_configured?(project_root)

      _, _, status = fetch_origin_branch(project_root, branch)
      return false unless status.success?

      origin_branch_ref_exists?(project_root, branch)
    end

    def self.origin_configured?(project_root)
      _, _, has_origin = Open3.capture3("git", "-C", project_root,
                                        "config", "remote.origin.url")
      has_origin.success?
    end

    def self.fetch_origin_branch(project_root, branch_name, timeout_sec: FETCH_TIMEOUT_SEC)
      # Fetch into an EXPLICIT colon-refspec so the local tracking ref
      # `refs/remotes/origin/<branch>` is written deterministically,
      # independent of the clone's configured fetch refspec. A plain
      # `git fetch origin <branch>` only updates FETCH_HEAD and relies on
      # git's opportunistic tracking-ref update, which fires SOLELY when a
      # configured wildcard refspec (+refs/heads/*:refs/remotes/origin/*)
      # matches. On a `--single-branch` / shallow / narrow-refspec clone
      # that wildcard is absent, so the tracking ref is never created and
      # `origin_branch_ref_exists?` wrongly reports a genuinely-present
      # branch as missing — silently collapsing dependency stacking onto
      # the default base (4-execute branches off origin/<default>,
      # 5-open-pr drops `--base <prereq>`). The leading `+` force-updates
      # the tracking ref exactly as the wildcard refspec would.
      timeout = Float(timeout_sec)
      raise ArgumentError, "fetch timeout must be positive" unless timeout.finite? && timeout.positive?

      success, err, timed_out = Hive::GitOps.new(project_root).run_git_with_timeout(
        [
        "git", "-C", project_root, "fetch", "origin",
        "+refs/heads/#{branch_name}:refs/remotes/origin/#{branch_name}"
        ],
        env: NONINTERACTIVE_FETCH_ENV,
        timeout_sec: timeout
      )
      if timed_out
        timeout_detail = "git fetch origin #{branch_name} timed out after #{timeout_sec}s"
        err = err.empty? ? timeout_detail : "#{err.rstrip}\n#{timeout_detail}"
      end
      [ "", err, FetchStatus.new(exitstatus: success ? 0 : 1) ]
    rescue StandardError => e
      [ "", e.message, FetchStatus.new(exitstatus: 1) ]
    end

    def self.origin_branch_ref_exists?(project_root, branch_name)
      _, _, status = Open3.capture3("git", "-C", project_root,
                                    "rev-parse", "--verify", "--quiet",
                                    "refs/remotes/origin/#{branch_name}")
      status.success?
    end

    def self.local_branch_ref_exists?(project_root, branch_name)
      branch = branch_name.to_s.strip
      return false if branch.empty?

      _, _, status = Open3.capture3("git", "-C", project_root,
                                    "rev-parse", "--verify", "--quiet",
                                    "refs/heads/#{branch}")
      status.success?
    end

    def self.materialize_pr(repo_root:, pr_number:, path:, branch:)
      repo_root = File.expand_path(repo_root)
      path = File.expand_path(path)
      pr_number = pr_number.to_i
      local_ref = "refs/#{branch}"

      FileUtils.mkdir_p(File.dirname(path))
      # Use the same non-interactive fetch env as every other fetch in this
      # file (GIT_TERMINAL_PROMPT=0 + SSH BatchMode + the HTTPS low-speed
      # abort). `hive review --pr N` fetches a PR head from an arbitrary
      # origin through the new CLI/--json entry point; without this an
      # unreachable or auth-required remote could hang on a credential
      # prompt or a dead connection instead of failing fast.
      run_materialize_git!(repo_root, "fetch", "origin", "+pull/#{pr_number}/head:#{local_ref}",
                           env: NONINTERACTIVE_FETCH_ENV)
      run_materialize_git!(repo_root, "worktree", "add", "-B", branch, path, local_ref)
      {
        path: path,
        branch: branch,
        head_sha: run_materialize_git!(path, "rev-parse", "HEAD").strip
      }
    end

    # Resolve symlinks before the prefix check — File.expand_path normalises
    # `..` and `~` lexically but does not follow symlinks. An agent that
    # writes a symlink at the worktree path could otherwise escape the root.
    def self.validate_pointer_path(pointer_path, expected_root)
      expanded = realpath_or_expand(pointer_path)
      expected_prefix = realpath_or_expand(expected_root)
      unless expanded.start_with?(expected_prefix + File::SEPARATOR) || expanded == expected_prefix
        raise WorktreeError,
              "worktree path #{expanded} is outside expected root #{expected_prefix}"
      end

      expanded
    end

    def self.realpath_or_expand(path)
      File.realpath(path)
    rescue Errno::ENOENT
      # Path doesn't exist yet (init pass before mkdir); fall back to lexical.
      File.expand_path(path)
    end

    # Run one `git -C <dir>` command for the materialize path and return its
    # stdout. `dir` is the directory git runs in — the repo root for fetch /
    # worktree-add, or the worktree `path` for `rev-parse HEAD`. `env: {}` is
    # an empty env (≡ no env arg to Open3.capture3); pass NONINTERACTIVE_FETCH_ENV
    # for the network fetch. Callers that ignore the return value simply discard
    # the stdout.
    def self.run_materialize_git!(dir, *args, env: {})
      out, err, status = Open3.capture3(env, "git", "-C", dir, *args)
      return out if status.success?

      raise WorktreeError, "git #{args.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
    end

    private

    def assert_exact_branch_base!(branch_name, expected)
      head = self.class.run_materialize_git!(
        @project_root, "rev-parse", "refs/heads/#{branch_name}"
      ).strip
      self.class.run_materialize_git!(
        @project_root, "merge-base", "--is-ancestor", expected, head
      )
      head
    rescue WorktreeError
      raise WorktreeError, "branch #{branch_name} does not descend from pinned commit #{expected}"
    end

    # Detect a stacked placeholder: a same-named branch a prior dependency
    # run created at the default base but left no real work on. With a stacked
    # override such a branch is re-pointed onto the prerequisite rather than
    # attached as-is.
    #
    # Measurement basis: count the commits `branch_name` carries beyond the
    # default branch, measured against BOTH `origin/<default>` (when its
    # tracking ref `refs/remotes/origin/<default>` exists) and local
    # `<default>` (when that branch exists). The branch is an empty placeholder
    # when it carries no unique commits beyond EITHER ref. Both directions of
    # drift create empty placeholders that look non-empty against the wrong
    # ref: one created from `origin/<default>` (freshest_base) sits ahead of a
    # lagging local default, while one created from a local default that runs
    # ahead of a stale origin (freshest_base's fetch-failure fallback) sits
    # ahead of `origin/<default>`. Consulting both refs catches either. Always
    # measured vs the default branch, never `base_override` (R1).
    #
    # Fail-closed: a branch is deleted only on positive proof of emptiness
    # (some default ref measures zero). Any git error skips that ref rather
    # than counting it as proof, and if no ref could be measured the branch is
    # preserved and attached as-is — stacking never deletes a branch it could
    # not positively prove empty. Each skipped/absent measurement is warned so
    # a dropped re-point is observable instead of silent.
    def empty_placeholder?(branch_name, default_branch)
      base_refs = default_base_refs(default_branch)
      if base_refs.empty?
        warn "[hive] worktree base: cannot measure #{branch_name} against #{default_branch} " \
             "(no origin/#{default_branch} or local #{default_branch} ref); preserving branch as-is"
        return false
      end

      measured = false
      base_refs.each do |base_ref|
        out, err, status = Open3.capture3("git", "-C", @project_root,
                                          "rev-list", "--count", "#{base_ref}..refs/heads/#{branch_name}")
        unless status.success?
          warn "[hive] worktree base: cannot measure #{branch_name} against #{base_ref} " \
               "(#{err.strip[0, 200]}); skipping this base"
          next
        end

        measured = true
        # Empty against EITHER default ref ⇒ the placeholder carries no unique
        # work (it sits at one default's tip), so re-pointing is safe.
        return true if out.strip == "0"
      end

      unless measured
        warn "[hive] worktree base: cannot measure #{branch_name} against any default ref " \
             "(origin/#{default_branch}, #{default_branch}); preserving branch as-is"
      end

      false
    end

    # Default refs to measure a placeholder's emptiness against: `origin/<default>`
    # when its tracking ref exists, and local `<default>` when that branch
    # exists. A placeholder is empty if it carries no commits beyond either.
    def default_base_refs(default_branch)
      refs = []
      refs << "origin/#{default_branch}" if self.class.origin_branch_ref_exists?(@project_root, default_branch)
      refs << default_branch if self.class.local_branch_ref_exists?(@project_root, default_branch)
      refs
    end

    def delete_local_branch!(branch_name)
      out, err, status = Open3.capture3("git", "-C", @project_root, "branch", "-D", branch_name)
      return if status.success?

      detail = err.strip.empty? ? out.strip : err.strip
      raise WorktreeError,
            "cannot re-point empty placeholder branch #{branch_name}: git branch -D failed: " \
            "#{detail} (is #{branch_name} checked out in another worktree?)"
    end

    # Stack on the requested override when possible, else degrade gracefully.
    # `reason` is the distinguishing clause (no origin / fetch failed / ref
    # missing) explaining why `origin/<branch>` is unusable; both arms build
    # their full warning from it. A present local prereq is stacked on
    # directly; otherwise we fall back through `freshest_base` to the default
    # branch base. The default-fallback tail names the default branch base
    # generically because `freshest_base` resolves it to `origin/<default>` on
    # a successful fetch and only local `<default>` if that fetch also fails.
    def override_local_or_default(branch, default_branch, reason)
      if self.class.local_branch_ref_exists?(@project_root, branch)
        warn "[hive] worktree base: #{reason}; stacking on local #{branch}"
        # Fully-qualify the start-point: a bare `<branch>` resolves through
        # gitrevisions precedence, where a same-named tag (refs/tags/<branch>)
        # shadows refs/heads/<branch>. The local ref was just verified to
        # exist, so refs/heads/<branch> is unambiguous and strictly safer.
        return "refs/heads/#{branch}"
      end

      warn "[hive] worktree base: #{reason}; " \
           "falling back to the default branch base (origin/#{default_branch} when reachable)"
      freshest_base(default_branch)
    end
  end
end
