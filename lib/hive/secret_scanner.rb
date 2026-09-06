require "tmpdir"
require "json"
require "digest"
require "open3"
require "hive"
require "hive/agent_git_gate"
require "hive/betterleaks"

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
      end
    end

    def git_match?(path, base_oid:, head_oid:)
      # These closed reads validate exact OIDs, repository custody, and unsafe
      # local Git helpers before Betterleaks invokes Git itself.
      [ base_oid, head_oid ].each do |oid|
        read!(path, :commit_oid, oid: oid)
      end
      !git_scan(path, "--log-opts",
                "--full-history --diff-merges=separate --text --no-ext-diff --no-textconv #{base_oid}..#{head_oid} --").empty?
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
          sha256: Digest::SHA256.hexdigest(record.fetch("Secret")) }
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
    private_class_method :run, :read!, :git_scan
  end
end
