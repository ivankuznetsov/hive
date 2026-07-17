# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

module HiveBench
  # Restores a repo at an exact base commit and captures candidate diffs, with
  # every git invocation hardened against a hostile repo turning a "read-only"
  # operation into arbitrary code execution.
  #
  # The threat (flagged in hive's learnings): a repo's `.git/config` /
  # `.gitattributes` can wire a `diff.<driver>.textconv` or `core.fsmonitor`
  # command that git executes during diff/status. Corpus entries and especially
  # untrusted submissions must never get to run code on the host through this.
  #
  # Defenses, applied to every git call here:
  #   - HOME / XDG_CONFIG_HOME pointed at an empty dir, GIT_CONFIG_GLOBAL=/dev/null,
  #     GIT_CONFIG_NOSYSTEM=1  -> no global/system config or hooks fire.
  #   - `-c core.fsmonitor=false -c core.hooksPath=/dev/null`  -> no fsmonitor/hook exec.
  #   - diffs add `--no-ext-diff --no-textconv`  -> repo-LOCAL textconv/ext-diff drivers
  #     (which our env hardening can't disable) never execute.
  #
  # Network: restore clones from `source`, which may be a local path (offline,
  # used for the hive corpus and tests) or a URL. This is the *generation*-phase
  # restore; the no-network gate lives in U4.
  class GitRestore
    class Error < StandardError; end

    HARDENED_CONFIG = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"].freeze
    DIFF_SAFETY = ["--no-ext-diff", "--no-textconv"].freeze
    # Trees an agent may create as a build side-effect (gem/npm install) — not part
    # of the candidate solution, and enormous. Excluded from the captured diff so a
    # vendored gem/node tree can't bury the real changes or blow up the judge's
    # tokens. Bundler vendors to `vendor/bundle` by default but also commonly to
    # `vendor/gems` (`bundle install --path vendor/gems`) and `vendor/cache`
    # (`bundle cache`) — all three are build output, never a deliverable. (Observed:
    # glm vendored 1217 gem files into vendor/gems on the install task → a 160k-line
    # diff that overflowed both judges.)
    VENDORED_EXCLUDES = [
      ":(exclude,glob).gems/**", ":(exclude).gems",
      ":(exclude,glob)**/node_modules/**",
      ":(exclude,glob)vendor/bundle/**", ":(exclude,glob)vendor/gems/**",
      ":(exclude,glob)vendor/cache/**", ":(exclude,glob).bundle/**",
      ":(exclude,glob).bundle-local/**", ":(exclude).bundle-local",
      ":(exclude).hive-bench-prompt.md"
    ].freeze

    def initialize
      # A throwaway empty HOME so no real user git config is ever consulted.
      @empty_home = Dir.mktmpdir("hb-githome")
      @env = {
        "HOME" => @empty_home,
        "XDG_CONFIG_HOME" => File.join(@empty_home, "xdg"),
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0"
      }.freeze
    end

    # Clone `source` into `into` and check out `base_commit`. `into` must resolve
    # inside its declared parent (no traversal). Raises Error on any failure.
    def restore(source:, base_commit:, into:)
      guard_target!(into)
      # Idempotent: a prior crashed/killed run can leave a populated `into`, which
      # would make `git clone` fail ("destination exists"). Re-cloning is the
      # correct behavior for re-running a cell whose generation was incomplete.
      FileUtils.rm_rf(into)
      FileUtils.mkdir_p(File.dirname(into))

      git!(*HARDENED_CONFIG, "clone", "--quiet", "--no-checkout", "--no-local", source.to_s, into)
      # Detached checkout at the exact base — never the source tip. Hardened so
      # the freshly-cloned repo's own config can't fire fsmonitor/hooks here.
      out, ok, err = git("-C", into, *HARDENED_CONFIG, "checkout", "--quiet", "--detach", base_commit.to_s)
      raise Error, "could not check out base commit #{short(base_commit)}: #{err.strip}#{out.strip}" unless ok

      into
    end

    # Unified diff of the working tree against `base_commit`, hardened so no
    # repo-controlled driver executes. Returns the patch string (possibly empty).
    def diff(work_dir:, base_commit:)
      # Record intent-to-add so NEW files appear in the diff — `git diff <commit>`
      # omits untracked files, which would silently drop a candidate that solves a
      # task mostly by ADDING files (install scripts, new modules, …). Vendored
      # trees are excluded so they neither bury the solution nor explode the diff.
      untracked, ok, err = git("-C", work_dir, *HARDENED_CONFIG, "ls-files", "--others",
                               "--exclude-standard", "-z", "--", ".", *VENDORED_EXCLUDES)
      raise Error, "git untracked-file scan failed: #{err.strip}" unless ok

      unless untracked.empty?
        _out, ok, err = git("-C", work_dir, *HARDENED_CONFIG, "--literal-pathspecs", "add", "--intent-to-add",
                            "--pathspec-from-file=-", "--pathspec-file-nul", stdin_data: untracked)
        raise Error, "git intent-to-add failed: #{err.strip}" unless ok
      end

      out, ok, err = git("-C", work_dir, *HARDENED_CONFIG, "diff", *DIFF_SAFETY,
                         base_commit.to_s, "--", ".", *VENDORED_EXCLUDES)
      raise Error, "git diff failed: #{err.strip}" unless ok

      out
    end

    # Hardened diff of `base..head` inside an existing repo (no checkout). Used to
    # recover a recorded agent's RAW execute output (provenance.execute_base_head)
    # for a reused incumbent cell — never the merged reference, which is the gold.
    def range_diff(repo:, base:, head:)
      out, ok, err = git("-C", repo.to_s, *HARDENED_CONFIG, "diff", *DIFF_SAFETY, "#{base}..#{head}", "--")
      raise Error, "git range diff #{short(base)}..#{short(head)} failed: #{err.strip}" unless ok

      out
    end

    # Applies a candidate patch to a restored work tree (hardened: no ext-diff /
    # textconv / hooks can fire during apply). Returns true on success, false if
    # the patch does not apply cleanly — the caller records that as a gate error,
    # not a test failure.
    def apply(work_dir:, patch:)
      patch_file = File.join(work_dir, ".hive-bench-candidate.patch")
      File.write(patch_file, patch)
      _out, ok, _err = git("-C", work_dir, *HARDENED_CONFIG, "apply", "--whitespace=nowarn", patch_file)
      ok
    ensure
      FileUtils.rm_f(patch_file) if patch_file
    end

    # Best-effort cleanup of the throwaway HOME.
    def close
      FileUtils.remove_entry(@empty_home) if @empty_home && File.directory?(@empty_home)
    end

    private

    # Reject any restore target containing a `..` traversal segment, mirroring
    # hive's Worktree.validate_pointer_path. Restore targets are always clean
    # paths the harness controls; a `..` means a submitted manifest is trying to
    # escape the run sandbox, which must hard-fail.
    def guard_target!(into)
      segments = into.to_s.split(%r{[/\\]})
      return unless segments.include?("..")

      raise Error, "unsafe restore target (path traversal `..` outside the sandbox): #{into}"
    end

    def git!(*args)
      out, ok, err = git(*args)
      raise Error, "git #{args.first(2).join(" ")} failed: #{err.strip}" unless ok

      out
    end

    # All git runs go through here so the hardened env is never bypassed.
    def git(*, stdin_data: nil)
      options = stdin_data.nil? ? {} : { stdin_data: stdin_data }
      out, err, status = Open3.capture3(@env, "git", *, **options)
      [out, status.success?, err]
    end

    def short(sha)
      sha.to_s[0, 10]
    end
  end
end
