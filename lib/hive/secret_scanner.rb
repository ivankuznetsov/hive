require "tmpdir"
require "json"
require "digest"
require "open3"
require "hive"
require "hive/agent_git_gate"
require "hive/betterleaks"
require "hive/paths"

module Hive
  # Betterleaks owns detection. Hive owns the exact input, trusted configuration,
  # and failure policy. Scanner output is never copied into task logs.
  module SecretScanner
    class Unavailable < Hive::Error; end

    FINDINGS_EXIT = 42
    POLICY_VERSION = "betterleaks-#{Hive::Betterleaks::VERSION}".freeze
    FLAGS = %w[
      --no-banner --no-color --log-level=fatal --report-format=json --report-path=-
      --ignore-gitleaks-allow --validation=false --max-target-megabytes=0
    ].freeze

    module_function

    def match?(text, path: "")
      !scan(text, path: path).empty?
    end

    def scan(text, path: "")
      return [] if text.to_s.empty?

      Dir.mktmpdir("hive-secret-scan-") do |directory|
        run(directory, "stdin", "--set-attr", "path=#{path}", input: text)
      end.map { |hit| hit.except(:commit) }
    end

    def git_match?(path, base_oid:, head_oid:, upstream_branch: nil)
      !git_findings(path, base_oid: base_oid, head_oid: head_oid, upstream_branch: upstream_branch).empty?
    end

    # `upstream_branch` (the PR base branch) scopes the history scan to the
    # task's own content. Commits already on upstream are excluded, and a
    # finding attributed to a merge commit is dropped only when an
    # upstream-side parent already carries that exact finding at that path:
    # merging origin/<default> re-diffs every upstream change against the
    # task-side parent, and that content is not the task's. Conflict
    # resolution and task-side content stay reported. An unresolvable
    # upstream ref, no merge base, or a head already on upstream keeps the
    # full scan; Git failures while scoping raise Unavailable.
    def git_findings(path, base_oid:, head_oid:, upstream_branch: nil)
      # These closed reads validate exact OIDs, repository custody, and unsafe
      # local Git helpers before Betterleaks invokes Git itself.
      [ base_oid, head_oid ].each do |oid|
        read!(path, :commit_oid, oid: oid)
      end
      upstream = scan_upstream_oid(path, upstream_branch, head_oid)
      exclusion = upstream ? " ^#{upstream}" : ""
      findings = git_scan(path, "--log-opts",
                          "--full-history --diff-merges=separate --text --no-ext-diff --no-textconv " \
                          "#{base_oid}..#{head_oid}#{exclusion} --")
      findings = drop_upstream_merge_findings(path, upstream, findings) if upstream
      findings.map { |hit| hit.except(:commit) }
    end

    def scan_upstream_oid(path, branch, head_oid)
      return nil if branch.to_s.strip.empty?

      target = Hive::AgentGitGate.read(path, :branch_oid, branch: branch, remote: true)
      target = Hive::AgentGitGate.read(path, :branch_oid, branch: branch) unless target.success?
      return nil unless target.success?

      upstream = target.stdout.strip
      return nil unless Hive::AgentGitGate.read(path, :merge_base, base_oid: upstream, head_oid: head_oid).success?
      return nil if ancestor?(path, head_oid, upstream)

      upstream
    rescue Hive::AgentGitGate::Error
      nil
    end

    def drop_upstream_merge_findings(path, upstream, findings)
      upstream_parents = Hash.new do |cache, commit|
        parents = commit_parents(path, commit)
        cache[commit] = parents.one? ? [] : parents.select { |parent| ancestor?(path, parent, upstream) }
      end
      findings.reject do |hit|
        upstream_parents[hit[:commit]].any? { |parent| carried_by?(path, parent, hit) }
      end
    end

    def commit_parents(path, commit)
      read!(path, :object_content, oid: commit).each_line.take_while { |line| line != "\n" }
                                                .filter_map { |line| line[/\Aparent ([0-9a-f]{40,64})$/, 1] }
    end

    def ancestor?(path, ancestor, descendant)
      result = Hive::AgentGitGate.read(path, :ancestor, base_oid: ancestor, head_oid: descendant)
      return result.success? if [ 0, 1 ].include?(result.exitstatus)

      raise Unavailable, "secret scan Git ancestry is unavailable"
    rescue Hive::AgentGitGate::Error
      raise Unavailable, "secret scan Git input is invalid"
    end

    # A missing path on the upstream parent means the content is not
    # upstream's; keep the finding (fail closed).
    def carried_by?(path, parent, hit)
      blob = Hive::AgentGitGate.read(path, :object_content, oid: parent, path: hit.fetch(:path))
      return false unless blob.success?

      scan(blob.stdout, path: hit.fetch(:path)).any? { |prior| prior.values_at(:name, :sha256) == hit.values_at(:name, :sha256) }
    rescue Hive::AgentGitGate::Error
      false
    end

    def staged_findings(path, entries:, head_objects:)
      entries.flat_map do |entry|
        file = entry.fetch(:path)
        current = scan(read!(path, :object_content, oid: entry.fetch(:object_id)), path: file)
        next [] if current.empty?

        previous_oid = head_objects[file]
        previous = previous_oid ? scan(read!(path, :object_content, oid: previous_oid), path: file) : []
        previous_keys = previous.map { |hit| hit.values_at(:name, :sha256) }
        current.reject { |hit| previous_keys.include?(hit.values_at(:name, :sha256)) }
               .map { |hit| hit.merge(path: file) }
      end
    end

    def git_scan(path, *arguments)
      git_dir = read!(path, :git_dir).strip
      # Use Betterleaks' native exact-fingerprint exceptions, owned by the
      # operator outside task worktrees. Repository suppressions stay ignored.
      ignore_path = File.join(Hive::Paths.config_home, "betterleaks.ignore")
      arguments += [ "--gitleaks-ignore-path", ignore_path ] if File.file?(ignore_path)
      Dir.mktmpdir("hive-secret-scan-") do |directory|
        # An empty view of the existing object database prevents task-authored
        # config/ignore files from becoming scanner policy. No checkout/copy.
        File.symlink(git_dir, File.join(directory, ".git"))
        run(directory, "git", directory, *arguments)
      end
    end

    def run(directory, *arguments, input: "")
      env = Hive::AgentGitGate.read_environment.merge(
        "PATH" => ENV.fetch("PATH"), "HOME" => directory,
        "BETTERLEAKS_CONFIG_TOML" => "prefilter = 'false'\n[extend]\nuseDefault = true\n"
      )
      output, _error, status = Open3.capture3(
        env, Hive::Betterleaks.executable, *arguments, *FLAGS, "--exit-code=#{FINDINGS_EXIT}",
        chdir: directory, unsetenv_others: true, stdin_data: input
      )
      unless status.success? || status.exitstatus == FINDINGS_EXIT
        raise Unavailable, "Betterleaks scan failed (exit #{status.exitstatus || 'signal'}); publication blocked"
      end
      # Raw findings remain in memory only. Callers get redacted labels and
      # hashes for comparing exact existing findings, never credential bytes.
      records = JSON.parse(output)
      records = [] if records.nil? && status.success?
      unless records.is_a?(Array) && (records.empty? == status.success?)
        raise Unavailable, "Betterleaks returned an inconsistent scan result"
      end
      records.map do |record|
        raise Unavailable, "Betterleaks returned an invalid finding" unless record.is_a?(Hash)

        { name: record.fetch("RuleID"), snippet: "[REDACTED]",
          line: record.fetch("StartLine"), column: record.fetch("StartColumn"),
          path: record.fetch("File"),
          fingerprint: record.fetch("Fingerprint", ""),
          sha256: Digest::SHA256.hexdigest(record.fetch("Secret")),
          commit: record.fetch("Commit", "").to_s }
      end

    rescue JSON::ParserError, KeyError, TypeError
      raise Unavailable, "Betterleaks returned an invalid scan result"
    rescue SystemCallError
      raise Unavailable, "Betterleaks could not run; repair the Hive installation and retry"
    end

    def read!(path, operation, **options)
      result = Hive::AgentGitGate.read(path, operation, **options)
      raise Unavailable, "secret scan Git input is unavailable" unless result.success?

      result.stdout
    rescue Hive::AgentGitGate::Error
      raise Unavailable, "secret scan Git input is invalid"
    end
    private_class_method :run, :read!, :git_scan, :scan_upstream_oid, :drop_upstream_merge_findings,
                         :commit_parents, :ancestor?, :carried_by?
  end
end
