# frozen_string_literal: true

require "open3"
require "json"
require "hive"
require "hive/config"

module Hive
  module Commands
    # `hive bench submit SLUG [--project NAME]` — extracts a completed (9-done)
    # task into a hive-bench corpus entry and opens a submission PR. A thin,
    # low-friction wrapper over hive-bench's own extractor (reused wholesale, not
    # duplicated) plus a local secret preflight so a contributor never opens a PR
    # that the hive-bench validator would reject for leaked credentials.
    #
    # Locates the hive-bench checkout via HIVE_BENCH_PATH (or ~/Dev/hive-bench).
    # The extractor invocation and the PR open are seams for testing.
    class BenchSubmit
      DEFAULT_BENCH_PATH = File.expand_path("~/Dev/hive-bench")
      DEFAULT_REPO = "ivankuznetsov/hive-bench"

      class UsageError < Hive::Error
        def exit_code = Hive::ExitCodes::USAGE
      end

      # extractor: ->(task_dir:, repo:, repo_path:, out_dir:) => entry_dir
      # pr_opener: ->(bench_path:, entry_dir:, slug:) => pr_url
      # secret_preflight: ->(paths) => [findings]
      def initialize(slug, project: nil, bench_path: nil, repo: DEFAULT_REPO, json: false,
                     extractor: nil, pr_opener: nil, secret_preflight: nil,
                     projects: nil, repo_path: nil)
        @slug = slug.to_s
        @project = project
        @bench_path = bench_path || ENV["HIVE_BENCH_PATH"] || DEFAULT_BENCH_PATH
        @repo = repo
        @json = json
        @extractor = extractor || method(:extract_via_hive_bench)
        @pr_opener = pr_opener || method(:open_pr_via_gh)
        @secret_preflight = secret_preflight || method(:local_secret_scan)
        @projects = projects
        @repo_path = repo_path
      end

      def call
        raise UsageError, "slug required" if @slug.empty?
        raise UsageError, "hive-bench checkout not found at #{@bench_path} (set HIVE_BENCH_PATH)" unless Dir.exist?(@bench_path)

        task_dir, project_root = resolve_done_task!
        verify_extractable!(task_dir)

        findings = @secret_preflight.call(spec_paths(task_dir))
        unless findings.empty?
          raise UsageError, "secret/PII found in the task spec — aborting before PR:\n  #{findings.join("\n  ")}"
        end

        entry_dir = @extractor.call(task_dir: task_dir, repo: source_repo(project_root),
                                    repo_path: project_root, out_dir: File.join(@bench_path, "corpus"))
        pr_url = @pr_opener.call(bench_path: @bench_path, entry_dir: entry_dir, slug: @slug)
        report(entry_dir, pr_url)
      end

      private

      # Find <project>/.hive-state/stages/9-done/<slug> across registered projects.
      def resolve_done_task!
        candidates = registered.filter_map do |proj|
          dir = File.join(proj["path"], ".hive-state", "stages", "9-done", @slug)
          [ dir, proj["path"] ] if Dir.exist?(dir)
        end
        raise UsageError, "no completed (9-done) task '#{@slug}' found#{@project ? " in #{@project}" : ''}" if candidates.empty?
        raise UsageError, "'#{@slug}' is ambiguous across projects; pass --project" if candidates.size > 1

        candidates.first
      end

      def registered
        all = @projects || Hive::Config.registered_projects
        @project ? all.select { |p| p["name"] == @project } : all
      end

      def verify_extractable!(task_dir)
        wt = File.join(task_dir, "worktree.yml")
        pr = File.join(task_dir, "pr.md")
        raise UsageError, "task has no worktree.yml (not extractable)" unless File.file?(wt)
        raise UsageError, "task has no pr.md (no reference PR to extract)" unless File.file?(pr)
      end

      def spec_paths(task_dir)
        %w[idea.md brainstorm.md plan.md task.md pr.md].map { |f| File.join(task_dir, f) }.select { |p| File.file?(p) }
      end

      def source_repo(project_root)
        @repo_path ||= project_root
        out, _err, status = Open3.capture3("git", "-C", project_root, "remote", "get-url", "origin")
        raise UsageError, "cannot read origin remote of #{project_root}" unless status.success?

        out.strip[%r{github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?\z}, 1] ||
          raise(UsageError, "origin is not a github.com remote: #{out.strip}")
      end

      # --- default seams ---

      def extract_via_hive_bench(task_dir:, repo:, repo_path:, out_dir:)
        script = File.join(@bench_path, "harness", "extract.rb")
        raise UsageError, "hive-bench extractor not found at #{script}" unless File.file?(script)

        # Array-form Open3 — no shell, no injection. -I and its path are
        # separate args (avoids interpolating into a single token).
        cmd = [ "ruby", "-I", File.join(@bench_path, "harness"), script,
               "--task-dir", task_dir, "--repo", repo, "--repo-path", repo_path,
               "--out", out_dir, "--plan-author", "claude" ]
        _out, err, status = Open3.capture3(*cmd)
        raise UsageError, "extraction failed: #{err.strip}" unless status.success?

        File.join(out_dir, @slug)
      end

      def open_pr_via_gh(bench_path:, entry_dir:, slug:)
        branch = "submit-#{slug}"
        run_git(bench_path, "checkout", "-b", branch)
        run_git(bench_path, "add", entry_dir)
        run_git(bench_path, "commit", "-qm", "corpus: add #{slug}")
        run_git(bench_path, "push", "-q", "-u", "origin", branch)
        out, err, status = Open3.capture3("gh", "pr", "create", "-R", @repo,
                                          "--title", "corpus: add #{slug}",
                                          "--body", "Adds the `#{slug}` task to the hive-bench corpus (via `hive bench submit`).",
                                          chdir: bench_path)
        raise UsageError, "gh pr create failed: #{err.strip}" unless status.success?

        out.strip
      end

      def run_git(dir, *args)
        _out, err, status = Open3.capture3("git", "-C", dir, *args)
        raise UsageError, "git #{args.first} failed: #{err.strip}" unless status.success?
      end

      def local_secret_scan(paths)
        patterns = {
          "private key" => /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
          "github token" => /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
          "openai key" => /\bsk-(?:ant-)?[A-Za-z0-9-]{20,}\b/,
          "aws key" => /\bAKIA[0-9A-Z]{16}\b/
        }
        paths.flat_map do |path|
          File.read(path).each_line.with_index.filter_map do |line, i|
            label, = patterns.find { |_l, re| line.match?(re) }
            "#{label} in #{File.basename(path)}:#{i + 1}" if label
          end
        end
      end

      def report(entry_dir, pr_url)
        if @json
          puts JSON.generate("schema" => "hive-bench-submit", "slug" => @slug,
                             "entry" => entry_dir, "pr_url" => pr_url)
        else
          puts "Submitted #{@slug} → #{pr_url}"
        end
        pr_url
      end
    end
  end
end
