require "digest"
require "fileutils"
require "time"
require "hive/gh/repository_identity"

module Hive
  module Digest
    PR_METRICS = %i[additions deletions commits].freeze

    RepositoryTarget = Data.define(:project_name, :path, :repository, :host) do
      def initialize(project_name:, path:, repository:, host:)
        project = project_name.to_s.strip
        raise ArgumentError, "digest project name must not be blank" if project.empty?

        super(
          project_name: project,
          path: File.expand_path(path.to_s),
          repository: Hive::Gh::RepositoryIdentity.validated_repository_slug(repository),
          host: Hive::Gh::RepositoryIdentity.validated_github_host(host)
        )
      end

      def key = "#{host.downcase}/#{repository.downcase}"
    end

    RepositoryMetadata = Data.define(:name, :description, :url) do
      def initialize(name:, description:, url:)
        raise ArgumentError, "digest repository name must not be blank" if name.to_s.strip.empty?
        raise ArgumentError, "digest repository URL must not be blank" if url.to_s.strip.empty?

        super(name: name.to_s.strip, description: description.to_s.strip, url: url.to_s.strip)
      end
    end

    EvidenceFile = Data.define(:path, :bytes, :sha256) do
      def initialize(path:, bytes:, sha256:)
        expanded = File.expand_path(path.to_s)
        size = Integer(bytes)
        checksum = sha256.to_s
        raise ArgumentError, "digest evidence path must be absolute" unless expanded == path.to_s
        raise ArgumentError, "digest evidence bytes must not be negative" if size.negative?
        unless checksum.match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError, "digest evidence checksum must be SHA-256"
        end

        super(path: expanded, bytes: size, sha256: checksum)
      end

      def each_line(&block)
        return enum_for(__method__) unless block

        File.foreach(path, mode: "rb", &block)
      end

      def empty? = bytes.zero?
    end

    PullRequestIdentity = Data.define(:repository, :number, :url, :merged_at) do
      def initialize(repository:, number:, url:, merged_at:)
        slug = Hive::Gh::RepositoryIdentity.validated_repository_slug(repository)
        parsed_number = Integer(number)
        raise ArgumentError, "digest PR number must be positive" unless parsed_number.positive?
        raise ArgumentError, "digest PR URL must not be blank" if url.to_s.strip.empty?

        timestamp = merged_at.is_a?(Time) ? merged_at : Time.iso8601(merged_at.to_s)
        super(repository: slug, number: parsed_number, url: url.to_s.strip, merged_at: timestamp)
      end

      def key = "#{repository.downcase}##{number}"
    end

    PullRequest = Data.define(
      :target, :number, :title, :url, :merged_at, :body, :diff, :files,
      :additions, :deletions, :commits
    ) do
      def initialize(target:, number:, title:, url:, merged_at:, body:, diff:, files:,
                     additions: nil, deletions: nil, commits: nil)
        identity = PullRequestIdentity.new(
          repository: target.repository, number: number, url: url, merged_at: merged_at
        )
        raise ArgumentError, "digest PR title must not be blank" if title.to_s.strip.empty?

        metrics = { additions: additions, deletions: deletions, commits: commits }.transform_values do |value|
          next nil if value.nil?

          parsed = Integer(value)
          raise ArgumentError, "digest PR metrics must be non-negative" if parsed.negative?

          parsed
        end
        body_evidence = evidence_value(body)
        diff_evidence = evidence_value(diff)
        super(
          target: target,
          number: identity.number,
          title: title.to_s.strip,
          url: identity.url,
          merged_at: identity.merged_at,
          body: body_evidence,
          diff: diff_evidence,
          files: Array(files).map(&:to_s).freeze,
          **metrics
        )
      end

      def repository = target.repository
      def project_name = target.project_name
      def identity = PullRequestIdentity.new(repository: repository, number: number, url: url, merged_at: merged_at)

      def to_h
        {
          "number" => number,
          "url" => url,
          "title" => title,
          "merged_at" => merged_at.utc.iso8601,
          "additions" => additions,
          "deletions" => deletions,
          "commits" => commits
        }.compact
      end


      private

      def evidence_value(value)
        return value if value.is_a?(EvidenceFile)

        value.to_s
      end
    end

    RepositoryCollection = Data.define(:target, :metadata, :pull_requests) do
      def initialize(target:, metadata:, pull_requests:)
        rows = Array(pull_requests)
        unless rows.all? { |pr| pr.target == target }
          raise ArgumentError, "digest repository collection contains a PR for another target"
        end

        super(target: target, metadata: metadata, pull_requests: rows.freeze)
      end
    end

    CollectionReport = Data.define(:resolved_count, :repositories, :failures, :warnings, :evidence_root) do
      def initialize(resolved_count:, repositories:, failures:, warnings:, evidence_root: nil)
        count = Integer(resolved_count)
        raise ArgumentError, "digest resolved repository count must not be negative" if count.negative?
        root = evidence_root && File.expand_path(evidence_root.to_s)
        if root && (!File.directory?(root) || !File.basename(root).start_with?("hive-digest-evidence-"))
          raise ArgumentError, "digest evidence root must be a collector-owned scratch directory"
        end

        super(
          resolved_count: count,
          repositories: Array(repositories).freeze,
          failures: Array(failures).freeze,
          warnings: Array(warnings).freeze,
          evidence_root: root
        )
      end

      def collected_count = repositories.size
      def pull_requests = repositories.flat_map(&:pull_requests)
      def all_failed? = repositories.empty?

      def cleanup!
        FileUtils.rm_rf(evidence_root) if evidence_root
      end
    end

    Warning = Data.define(:kind, :message, :repository, :pr_number, :metrics) do
      def initialize(kind:, message:, repository:, pr_number: nil, metrics: nil)
        kind_value = kind.to_s.strip
        message_value = message.to_s.strip
        repository_value = repository.to_s.strip
        raise ArgumentError, "digest warning kind must not be blank" if kind_value.empty?
        raise ArgumentError, "digest warning message must not be blank" if message_value.empty?
        raise ArgumentError, "digest warning repository must not be blank" if repository_value.empty?

        parsed_pr = pr_number.nil? ? nil : Integer(pr_number)
        raise ArgumentError, "digest warning PR number must be positive" if parsed_pr && !parsed_pr.positive?

        super(
          kind: kind_value,
          message: message_value,
          repository: repository_value,
          pr_number: parsed_pr,
          metrics: Array(metrics).map(&:to_s).reject(&:empty?).uniq.freeze
        )
      end

      def to_h
        {
          "kind" => kind,
          "message" => message,
          "repository" => repository,
          "pr_number" => pr_number,
          "metrics" => metrics.empty? ? nil : metrics
        }.compact
      end
    end

    Resolution = Data.define(:targets, :warnings) do
      def initialize(targets:, warnings:)
        super(targets: Array(targets).freeze, warnings: Array(warnings).freeze)
      end
    end
  end
end
