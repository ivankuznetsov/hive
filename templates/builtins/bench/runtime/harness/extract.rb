# frozen_string_literal: true

require "yaml"
require "json"
require "digest"
require "fileutils"
require "open3"
require "time"
require "lib/spec_normalizer"

module HiveBench
  # Turns a completed hive task folder (a `9-done` stage dir) into a portable,
  # reproducible corpus entry (see corpus/SCHEMA.md). External effects — the
  # reference-PR diff fetch and the original-model lookup — are injectable seams
  # so the extractor is fully testable offline against a fixture task folder.
  #
  #   HiveBench::Extract.new(
  #     task_dir: ".hive-state/stages/9-done/<slug>",
  #     repo_slug: "ivankuznetsov/hive",
  #     out_dir: "corpus",
  #   ).call
  class Extract
    SCHEMA = "hive-bench-corpus-entry"
    SCHEMA_VERSION = 1
    DEFAULT_ATTESTATION = "Extracted by the maintainer from a repo they have the right to publish."

    class Error < StandardError; end

    # reference_resolver: ->(repo_slug, pr_number) =>
    #   { "base_commit" => sha, "patch" => diff, "merge_commit" => sha }
    #   The base_commit it returns is the commit the patch applies to (the merge
    #   commit's first parent), NOT the task's execute_base_head — the gold patch
    #   is the PR's own net change (`git diff base..merge`), apply-clean at
    #   `base` by construction. execute_base_head is kept only as provenance.
    # model_lookup: ->(task_slug) => String|nil (model string from hive UsageDb)
    def initialize(task_dir:, repo_slug:, out_dir:, repo_path: nil,
                   reference_resolver: nil, model_lookup: nil,
                   plan_authorship: "unknown", attestation: DEFAULT_ATTESTATION,
                   clock: -> { Time.now.utc })
      @task_dir = task_dir
      @repo_slug = repo_slug
      @out_dir = out_dir
      @repo_path = repo_path
      @reference_resolver = reference_resolver || method(:resolve_reference_via_git)
      @model_lookup = model_lookup || method(:lookup_model_via_usage_db)
      @plan_authorship = plan_authorship
      @attestation = attestation
      @clock = clock
    end

    # Writes the entry under <out_dir>/<task_id>/ and returns the manifest hash.
    def call
      worktree = load_yaml!("worktree.yml")
      meta = load_yaml!("meta.yml")
      pr = pr_frontmatter!

      execute_base_head = worktree["execute_base_head"].to_s
      raise Error, "worktree.yml has no execute_base_head — task not extractable" if execute_base_head.empty?

      task_id = meta["slug"].to_s
      task_id = File.basename(@task_dir) if task_id.empty?

      # --- reference: base + gold patch, apply-clean at base by construction ---
      ref = @reference_resolver.call(@repo_slug, pr["pr_number"])
      base_commit = ref["base_commit"].to_s
      patch = ref["patch"].to_s
      raise Error, "reference resolver returned no base_commit for PR ##{pr["pr_number"]}" if base_commit.empty?
      raise Error, "reference PR ##{pr["pr_number"]} produced an empty diff" if patch.strip.empty?

      entry_dir = File.join(@out_dir, task_id)
      spec_dir = File.join(entry_dir, "spec")
      gate_dir = File.join(entry_dir, "gate")
      FileUtils.mkdir_p([spec_dir, gate_dir])

      # --- spec: copy + normalize the agent-visible inputs ---
      spec_files, norm_totals = write_spec(spec_dir)

      File.write(File.join(entry_dir, "reference.patch"), patch)
      write_gate_skeleton(gate_dir)

      manifest = build_manifest(
        task_id: task_id, base_commit: base_commit, execute_base_head: execute_base_head,
        merge_commit: ref["merge_commit"], pr_meta: pr, spec_files: spec_files,
        norm_totals: norm_totals, patch: patch, model: @model_lookup.call(task_id)
      )
      File.write(File.join(entry_dir, "manifest.yml"), manifest.to_yaml)
      manifest
    end

    private

    def build_manifest(task_id:, base_commit:, execute_base_head:, merge_commit:, pr_meta:, spec_files:, norm_totals:, patch:, model:)
      {
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "task_id" => task_id,
        "source" => {
          "repo" => @repo_slug,
          "base_commit" => base_commit,
          "merge_commit" => merge_commit,
          "reference_pr" => pr_meta["pr_number"],
          "reference_pr_url" => pr_meta["pr_url"]
        },
        "spec" => {
          "idea" => spec_files[:idea],
          "brainstorm" => spec_files[:brainstorm],
          "plan" => spec_files[:plan],
          "normalized" => true,
          "normalization" => {
            "rewritten_paths" => norm_totals[:rewritten_paths],
            "flagged_assertions" => norm_totals[:flagged_assertions]
          }
        },
        "reference" => {
          "patch" => "reference.patch",
          "sha256" => Digest::SHA256.hexdigest(patch),
          "held_out" => true
        },
        "gate" => { "spec" => "gate/gate.yml" },
        "provenance" => {
          "extracted_from" => @task_dir,
          "extracted_at" => @clock.call.iso8601,
          "execute_base_head" => execute_base_head,
          "original_model" => model || "unknown",
          "plan_authorship" => @plan_authorship,
          "attestation" => @attestation
        },
        "publish" => { "include_diff" => true, "include_spec" => true }
      }
    end

    # Copies idea/brainstorm/plan into spec/, normalizing each. Returns the
    # relative spec paths (nil for any source file absent) and the summed
    # normalization counts for provenance.
    def write_spec(spec_dir)
      sources = { idea: "idea.md", brainstorm: "brainstorm.md", plan: "plan.md" }
      files = {}
      totals = { rewritten_paths: 0, flagged_assertions: 0 }
      sources.each do |key, name|
        src = File.join(@task_dir, name)
        unless File.file?(src)
          files[key] = nil
          next
        end
        raw = File.read(src)
        report = SpecNormalizer.analyze(raw)
        totals[:rewritten_paths] += report[:rewritten_paths].size
        totals[:flagged_assertions] += report[:flagged_assertions].size
        File.write(File.join(spec_dir, name), SpecNormalizer.normalize(raw))
        files[key] = "spec/#{name}"
      end
      raise Error, "task folder has no plan.md — nothing to execute" if files[:plan].nil?

      [files, totals]
    end

    def write_gate_skeleton(gate_dir)
      gate = {
        "needs_curation" => true,
        "install_cmd" => nil,
        "test_cmd" => nil,
        "fail_to_pass" => [],
        "pass_to_pass" => []
      }
      File.write(File.join(gate_dir, "gate.yml"), gate.to_yaml)
    end

    def load_yaml!(name)
      path = File.join(@task_dir, name)
      raise Error, "missing #{name} in #{@task_dir}" unless File.file?(path)

      YAML.safe_load_file(path, permitted_classes: [Time]) || {}
    end

    # Reads the `---` YAML frontmatter block at the top of pr.md.
    def pr_frontmatter!
      path = File.join(@task_dir, "pr.md")
      raise Error, "missing pr.md in #{@task_dir}" unless File.file?(path)

      body = File.read(path)
      m = body.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      raise Error, "pr.md has no frontmatter block" unless m

      data = YAML.safe_load(m[1]) || {}
      raise Error, "pr.md frontmatter has no pr_number" unless data["pr_number"]

      data
    end

    # --- default seams (real external effects) ---

    # Derives the gold patch as the PR's own net change `git diff base..merge`,
    # where `base` is the merge commit's first parent — guaranteed apply-clean at
    # `base`. Needs a local clone of the source repo (@repo_path); the maintainer
    # has it, and the validator clones submissions anyway. Falls back to fetching
    # the merge commit if it isn't present locally.
    def resolve_reference_via_git(repo_slug, pr_number)
      raise Error, "reference resolution needs --repo-path <local clone of #{repo_slug}>" unless @repo_path

      merge = gh_json(repo_slug, pr_number, ".mergeCommit.oid")
      raise Error, "PR ##{pr_number} has no merge commit (not merged?)" if merge.to_s.empty?

      ensure_commit_present(merge)
      base = git!("rev-parse", "#{merge}~1").strip
      patch = git!("diff", base, merge)
      { "base_commit" => base, "merge_commit" => merge, "patch" => patch }
    end

    def gh_json(repo_slug, pr_number, jq_filter)
      out, err, status = Open3.capture3("gh", "pr", "view", pr_number.to_s, "-R", repo_slug, "--json", "mergeCommit", "--jq", jq_filter)
      raise Error, "gh pr view failed for #{repo_slug}##{pr_number}: #{err.strip}" unless status.success?

      out.strip
    end

    def ensure_commit_present(sha)
      return if git("cat-file", "-e", "#{sha}^{commit}")[1].success?

      git("fetch", "--quiet", "origin", sha)
      raise Error, "merge commit #{sha[0, 10]} not in #{@repo_path} (fetch failed)" unless git("cat-file", "-e",
                                                                                               "#{sha}^{commit}")[1].success?
    end

    def git!(*args)
      out, status = git(*args)
      raise Error, "git #{args.join(" ")} failed: #{@last_git_err.to_s.strip}" unless status.success?

      out
    end

    # Returns [stdout, status]; stderr is folded into Error messages by git!.
    def git(*)
      out, err, status = Open3.capture3("git", "-C", @repo_path, *)
      @last_git_err = err
      [out, status]
    end

    # Best-effort: read the execute-stage model from hive's UsageDb via the
    # sqlite3 CLI. Returns nil (→ "unknown") if the CLI, the DB, or a row is
    # absent — execute often runs in tmux and records no usage row.
    def lookup_model_via_usage_db(task_slug)
      db = ENV["HIVE_USAGE_DB_PATH"] || File.expand_path("~/.local/share/hive/usage.db")
      return nil unless File.file?(db)
      return nil if Open3.capture2e("sh", "-c", "command -v sqlite3").last.success? == false

      sql = "SELECT model FROM token_usage WHERE task_slug='#{task_slug.gsub("'", "''")}' " \
            "AND stage='4-execute' AND model IS NOT NULL AND model<>'' ORDER BY started_at LIMIT 1;"
      out, _err, status = Open3.capture3("sqlite3", db, sql)
      return nil unless status.success?

      v = out.strip
      v.empty? ? nil : v
    rescue StandardError
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  opts = { out_dir: "corpus", repo_slug: nil, task_dir: nil, repo_path: nil, plan_authorship: "unknown" }
  OptionParser.new do |o|
    o.banner = "Usage: ruby harness/extract.rb --task-dir DIR --repo owner/name --repo-path PATH [--out corpus] [--plan-author claude]"
    o.on("--task-dir DIR") { |v| opts[:task_dir] = v }
    o.on("--repo SLUG") { |v| opts[:repo_slug] = v }
    o.on("--repo-path PATH", "Local clone of the source repo (to derive the gold patch)") { |v| opts[:repo_path] = v }
    o.on("--out DIR") { |v| opts[:out_dir] = v }
    o.on("--plan-author NAME") { |v| opts[:plan_authorship] = v }
  end.parse!(ARGV)

  abort "extract: --task-dir and --repo are required" unless opts[:task_dir] && opts[:repo_slug]

  manifest = HiveBench::Extract.new(
    task_dir: opts[:task_dir], repo_slug: opts[:repo_slug], repo_path: opts[:repo_path],
    out_dir: opts[:out_dir], plan_authorship: opts[:plan_authorship]
  ).call
  warn "extracted #{manifest["task_id"]} -> #{File.join(opts[:out_dir], manifest["task_id"])} " \
       "(ref PR ##{manifest.dig("source", "reference_pr")}, base #{manifest.dig("source", "base_commit")[0, 10]}, " \
       "#{manifest.dig("spec", "normalization", "rewritten_paths")} paths rewritten)"
end
