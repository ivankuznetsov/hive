require "digest"
require "fileutils"
require "json"
require "logger"
require "tmpdir"
require "hive/digest/london_window"
require "hive/digest/repository"
require "hive/gh"
require "hive/secret_patterns"

module Hive
  module Digest
    class Collector
      MAX_PR_EVIDENCE_BYTES = 64 * 1024 * 1024
      MAX_REPOSITORY_EVIDENCE_BYTES = 256 * 1024 * 1024
      MAX_DIGEST_EVIDENCE_BYTES = 512 * 1024 * 1024
      LIMITS = {
        per_pr: MAX_PR_EVIDENCE_BYTES,
        per_repository: MAX_REPOSITORY_EVIDENCE_BYTES,
        per_digest: MAX_DIGEST_EVIDENCE_BYTES
      }.freeze
      PEM_BEGIN = /-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----/
      PEM_END = /-----END (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY(?: BLOCK)?-----/

      def initialize(gh: Hive::Gh, cfg: nil, logger: Logger.new($stderr), scratch_root: nil,
                     limits: LIMITS, redactor: Hive::SecretPatterns)
        @gh = gh
        @cfg = cfg
        @logger = logger
        @scratch_root = scratch_root
        @limits = LIMITS.keys.to_h { |key| [ key, Integer(limits.fetch(key)) ] }.freeze
        @redactor = redactor
      end

      def for_date(date, targets:)
        local_date = LondonWindow.parse_date(date)
        window_start, = LondonWindow.utc_bounds(local_date)
        successes = []
        failures = []
        warnings = []
        @digest_bytes = 0

        run_dir = create_scratch_dir
        begin
          Array(targets).each do |target|
            successes << collect_repository(
              target, local_date: local_date, window_start: window_start,
              run_dir: run_dir, warnings: warnings
            )
          rescue StandardError => e
            failure = collection_failure(target, e)
            failures << failure
            warnings << failure
            @logger&.warn("digest collector: #{failure.message}")
          end

          CollectionReport.new(
            resolved_count: Array(targets).size,
            repositories: successes,
            failures: failures,
            warnings: warnings,
            evidence_root: run_dir
          )
        rescue Exception
          FileUtils.rm_rf(run_dir)
          raise
        end
      end

      private

      def collect_repository(target, local_date:, window_start:, run_dir:, warnings:)
        repository_bytes = 0
        repo_dir = File.join(run_dir, safe_component(target.key))
        FileUtils.mkdir_p(repo_dir, mode: 0o700)
        File.chmod(0o700, repo_dir)
        raw_metadata = @gh.digest_repository_metadata(
          repository: target.repository, host: target.host, cfg: @cfg
        )
        metadata = build_metadata(target, raw_metadata, warnings)
        candidates = @gh.digest_merged_pr_candidates(
          repository: target.repository, host: target.host,
          window_start: window_start, cfg: @cfg
        )
        qualifying = candidates.select do |row|
          merged_at = row.fetch("merged_at")
          !merged_at.nil? && LondonWindow.on_date?(merged_at, local_date)
        end
        qualifying = qualifying.uniq { |row| Integer(row.fetch("number")) }
                               .sort_by { |row| [ Time.iso8601(row.fetch("merged_at").to_s), row.fetch("number") ] }

        pull_requests = qualifying.map do |candidate|
          pr, consumed = collect_pull_request(
            target, candidate, repo_dir: repo_dir, warnings: warnings,
            repository_bytes: repository_bytes
          )
          repository_bytes += consumed
          if repository_bytes > @limits.fetch(:per_repository)
            raise Hive::GhError,
                  "repository evidence exceeds the #{MAX_REPOSITORY_EVIDENCE_BYTES}-byte safety ceiling"
          end
          pr
        end

        RepositoryCollection.new(target: target, metadata: metadata, pull_requests: pull_requests)
      end

      def collect_pull_request(target, candidate, repo_dir:, warnings:, repository_bytes:)
        number = Integer(candidate.fetch("number"))
        detail = @gh.digest_pr_detail(
          repository: target.repository, host: target.host, number: number, cfg: @cfg
        )
        validate_candidate!(target, candidate, detail)
        files = @gh.digest_pr_files(
          repository: target.repository, host: target.host, number: number, cfg: @cfg
        )
        pr_dir = File.join(repo_dir, "pr-#{number}")
        FileUtils.mkdir_p(pr_dir, mode: 0o700)
        File.chmod(0o700, pr_dir)
        body = detail.fetch("body").to_s
        body_path = private_write(File.join(pr_dir, "body.raw"), body)
        diff_path = File.join(pr_dir, "diff.raw")
        begin
          diff_bytes = collect_diff_to_file(
            target, number, path: diff_path,
            max_bytes: remaining_diff_bytes(body.bytesize, repository_bytes: repository_bytes)
          )
          consumed = body.bytesize + diff_bytes
          enforce_pr_limit!(consumed)
          @digest_bytes += consumed
          if @digest_bytes > @limits.fetch(:per_digest)
            raise Hive::GhError,
                  "digest evidence exceeds the #{MAX_DIGEST_EVIDENCE_BYTES}-byte safety ceiling"
          end

          body_evidence = redact_evidence_file(
            body_path, File.join(pr_dir, "body.redacted"),
            target: target, number: number, warnings: warnings
          )
          diff_evidence = redact_evidence_file(
            diff_path, File.join(pr_dir, "diff.redacted"),
            target: target, number: number, warnings: warnings
          )
          validate_files_and_diff!(target, number, detail, files, diff_evidence)
          redacted = {
            "body" => body_evidence,
            "diff" => diff_evidence,
            "files" => files.map { |file| file.fetch("filename").to_s }
          }
          evidence_metadata = {
            "body" => evidence_metadata(body_evidence),
            "diff" => evidence_metadata(diff_evidence),
            "files" => redacted.fetch("files")
          }
          manifest_content = JSON.generate(evidence_metadata)
          manifest_path = private_write(File.join(pr_dir, "evidence.json"), manifest_content)
          checksum = ::Digest::SHA256.file(manifest_path).hexdigest
          unless checksum == ::Digest::SHA256.hexdigest(manifest_content)
            raise Hive::GhError, "redacted evidence checksum mismatch for #{target.repository}##{number}"
          end

          [ build_pull_request(target, detail, redacted, warnings), consumed ]
        ensure
          FileUtils.rm_f(body_path) if body_path
          FileUtils.rm_f(diff_path) if diff_path
        end
      end

      def collect_diff_to_file(target, number, path:, max_bytes:)
        if @gh.respond_to?(:digest_pr_diff_to_file)
          return @gh.digest_pr_diff_to_file(
            repository: target.repository, host: target.host, number: number,
            path: path, cfg: @cfg, max_bytes: max_bytes
          )
        end

        diff = @gh.digest_pr_diff(
          repository: target.repository, host: target.host, number: number,
          cfg: @cfg, max_bytes: max_bytes
        )
        private_write(path, diff)
        diff.bytesize
      end

      def build_metadata(target, doc, warnings)
        description = redact_evidence(
          doc.fetch("description").to_s, target: target, number: nil, warnings: warnings
        )
        RepositoryMetadata.new(
          name: doc.fetch("full_name"), description: description, url: doc.fetch("html_url")
        )
      end

      def build_pull_request(target, detail, redacted, warnings)
        number = detail.fetch("number")
        title = redact_evidence(detail.fetch("title"), target: target, number: number, warnings: warnings)
        PullRequest.new(
          target: target,
          number: number,
          title: title,
          url: detail.fetch("html_url"),
          merged_at: detail.fetch("merged_at"),
          body: redacted.fetch("body"),
          diff: redacted.fetch("diff"),
          files: redacted.fetch("files"),
          additions: optional_metric(detail, "additions"),
          deletions: optional_metric(detail, "deletions"),
          commits: optional_metric(detail, "commits")
        )
      end

      def validate_candidate!(target, candidate, detail)
        candidate_number = Integer(candidate.fetch("number"))
        candidate_merged_at = Time.iso8601(candidate.fetch("merged_at").to_s)
        detail_merged_at = Time.iso8601(detail.fetch("merged_at").to_s)
        return if candidate_number == detail.fetch("number") && candidate_merged_at == detail_merged_at

        raise Hive::GhError, "pull-request identity changed while collecting #{target.repository}##{candidate_number}"
      rescue KeyError, ArgumentError, TypeError => e
        raise Hive::GhError, "malformed pull-request identity for #{target.repository}: #{e.message}"
      end

      def validate_files_and_diff!(target, number, detail, files, diff)
        expected_count = detail.fetch("changed_files")
        file_paths = files.map { |file| file.fetch("filename").to_s }
        if file_paths.uniq.size != file_paths.size || file_paths.size != expected_count
          raise Hive::GhError,
                "changed-file count mismatch for #{target.repository}##{number}: " \
                "detail=#{expected_count}, files=#{file_paths.uniq.size}"
        end
        if expected_count.positive? && diff.empty?
          raise Hive::GhError, "raw diff is empty for #{target.repository}##{number}"
        end

        diff_paths = diff_file_paths(diff, expected_paths: file_paths)
        return if diff_paths.sort == file_paths.sort

        raise Hive::GhError, "changed-file identity mismatch for #{target.repository}##{number}"
      rescue KeyError => e
        raise Hive::GhError, "malformed changed-file metadata for #{target.repository}##{number}: #{e.message}"
      end

      def diff_file_paths(diff, expected_paths:)
        diff.each_line.filter_map do |line|
          next unless line.start_with?("diff --git ")

          payload = line.delete_suffix("\n").delete_suffix("\r").delete_prefix("diff --git ")
          path = parse_diff_header_paths(payload, expected_paths: expected_paths)
          unless path.start_with?("b/")
            raise Hive::GhError, "raw diff contains an invalid destination path"
          end
          path.delete_prefix("b/")
        end
      end

      def parse_diff_header_paths(payload, expected_paths:)
        destination, destination_offset = quoted_destination(payload)
        unless destination
          matches = expected_paths.select { |candidate| payload.end_with?(" b/#{candidate}") }
          raise Hive::GhError, "raw diff contains an ambiguous file header" if matches.size > 1
          if matches.one?
            destination = "b/#{matches.first}"
            destination_offset = payload.bytesize - destination.bytesize
          else
            separator = payload.rindex(" b/")
            raise Hive::GhError, "raw diff contains an invalid file header" unless separator

            destination_offset = separator + 1
            destination = payload.byteslice(destination_offset..)
          end
        end

        source = payload.byteslice(0...destination_offset).to_s.rstrip
        if source.start_with?('"')
          decoded, final_offset = decode_git_quoted_path(source, 0)
          unless final_offset == source.bytesize && decoded.start_with?("a/")
            raise Hive::GhError, "raw diff contains an invalid source path"
          end
        elsif !source.start_with?("a/") || source == "a/"
          raise Hive::GhError, "raw diff contains an invalid source path"
        end
        destination
      end

      def quoted_destination(payload)
        offsets = []
        payload.bytes.each_index do |index|
          offsets << index if payload.getbyte(index) == 34 && index.positive? && payload.getbyte(index - 1) == 32
        end
        offsets.reverse_each do |offset|
          destination, final_offset = decode_git_quoted_path(payload, offset)
          next unless final_offset == payload.bytesize && destination.start_with?("b/")

          return [ destination, offset ]
        rescue Hive::GhError
          next
        end
        nil
      end

      GIT_QUOTED_ESCAPES = {
        97 => 7, 98 => 8, 116 => 9, 110 => 10, 118 => 11, 102 => 12,
        114 => 13, 34 => 34, 92 => 92
      }.freeze

      def decode_git_quoted_path(text, offset)
        unless text.getbyte(offset) == 34
          raise Hive::GhError, "raw diff contains an invalid quoted file header"
        end

        bytes = []
        index = offset + 1
        while index < text.bytesize
          byte = text.getbyte(index)
          if byte == 34
            value = bytes.pack("C*").force_encoding(Encoding::UTF_8)
            unless value.valid_encoding?
              raise Hive::GhError, "raw diff contains an invalid UTF-8 file path"
            end
            return [ value, index + 1 ]
          end
          if byte == 92
            index += 1
            escaped = text.getbyte(index)
            raise Hive::GhError, "raw diff contains a truncated file escape" unless escaped

            if escaped.between?(48, 55)
              digits = text.byteslice(index, 3).to_s[/\A[0-7]{1,3}/]
              value = digits.to_i(8)
              raise Hive::GhError, "raw diff contains an invalid file escape" if value > 255

              bytes << value
              index += digits.length
              next
            end
            decoded = GIT_QUOTED_ESCAPES[escaped]
            raise Hive::GhError, "raw diff contains an invalid file escape" unless decoded

            bytes << decoded
            index += 1
            next
          end
          bytes << byte
          index += 1
        end
        raise Hive::GhError, "raw diff contains an unterminated quoted file path"
      end

      def optional_metric(detail, key)
        value = detail[key]
        return nil if value.nil?
        return value if value.is_a?(Integer) && !value.negative?

        nil
      end

      def redact_evidence(text, target:, number:, warnings:)
        raw = text.to_s
        hits = @redactor.scan(raw)
        redacted = @redactor.redact(raw)
        verify_redaction!(redacted)
        add_redaction_warning(target, number, hits.map { |hit| hit.fetch(:name).to_s }.tally, warnings)
        redacted
      rescue EncodingError, SystemCallError => e
        raise Hive::GhError, "safe evidence redaction failed: #{e.class}"
      end

      def redact_evidence_file(source_path, destination_path, target:, number:, warnings:)
        counts = Hash.new(0)
        digest = ::Digest::SHA256.new
        bytes = 0
        in_private_key = false
        File.open(destination_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |output|
          File.foreach(source_path, mode: "rb") do |raw_line|
            line = raw_line.dup.force_encoding(Encoding::UTF_8)
            raise EncodingError, "invalid UTF-8 evidence" unless line.valid_encoding?

            if in_private_key
              in_private_key = false if line.match?(PEM_END)
              next
            end
            if line.match?(PEM_BEGIN)
              replacement = "[REDACTED:pem_private_key]\n"
              counts["pem_private_key"] += 1
              in_private_key = true unless line.match?(PEM_END)
            else
              hits = @redactor.scan(line)
              hits.each { |hit| counts[hit.fetch(:name).to_s] += 1 }
              replacement = @redactor.redact(line)
              verify_redaction!(replacement)
            end
            output.write(replacement)
            digest.update(replacement)
            bytes += replacement.bytesize
          end
        end
        File.chmod(0o600, destination_path)
        checksum = digest.hexdigest
        unless ::Digest::SHA256.file(destination_path).hexdigest == checksum
          raise Hive::GhError, "redacted evidence checksum mismatch for #{target.repository}##{number}"
        end
        add_redaction_warning(target, number, counts, warnings)
        EvidenceFile.new(path: destination_path, bytes: bytes, sha256: checksum)
      rescue EncodingError, SystemCallError => e
        FileUtils.rm_f(destination_path)
        raise Hive::GhError, "safe evidence redaction failed: #{e.class}"
      end

      def verify_redaction!(text)
        unless @redactor.scan(text).empty?
          raise Hive::GhError, "safe evidence redaction could not be verified"
        end
      end

      def add_redaction_warning(target, number, counts, warnings)
        unless counts.empty?
          scope = number ? "#{target.repository}##{number}" : target.repository
          warnings << Warning.new(
            kind: "evidence_redacted",
            repository: target.repository,
            pr_number: number,
            message: "Redacted recognized secret patterns from #{scope}: " \
                     "#{counts.sort.map { |name, count| "#{name}=#{count}" }.join(', ')}"
          )
        end
      end

      def evidence_metadata(evidence)
        evidence.to_h
      end

      def enforce_pr_limit!(bytes)
        return if bytes <= @limits.fetch(:per_pr)

        raise Hive::GhError,
              "pull-request evidence exceeds the #{MAX_PR_EVIDENCE_BYTES}-byte safety ceiling"
      end

      def remaining_diff_bytes(body_bytes, repository_bytes:)
        enforce_pr_limit!(body_bytes)
        repository_total = repository_bytes + body_bytes
        if repository_total > @limits.fetch(:per_repository)
          raise Hive::GhError,
                "repository evidence exceeds the #{MAX_REPOSITORY_EVIDENCE_BYTES}-byte safety ceiling"
        end
        digest_total = @digest_bytes + body_bytes
        if digest_total > @limits.fetch(:per_digest)
          raise Hive::GhError,
                "digest evidence exceeds the #{MAX_DIGEST_EVIDENCE_BYTES}-byte safety ceiling"
        end

        [
          @limits.fetch(:per_pr) - body_bytes,
          @limits.fetch(:per_repository) - repository_total,
          @limits.fetch(:per_digest) - digest_total
        ].min
      end

      def collection_failure(target, error)
        repository = target.respond_to?(:repository) ? target.repository : "<unknown>"
        message = @redactor.redact(error.message.to_s).lines.first.to_s.strip
        message = error.class.name if message.empty?
        Warning.new(
          kind: "repository_collection_failed",
          repository: repository,
          message: "Could not collect #{repository}: #{message}"
        )
      end

      def private_write(path, content)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(content)
        end
        File.chmod(0o600, path)
        path
      end

      def create_scratch_dir
        if @scratch_root
          FileUtils.mkdir_p(@scratch_root, mode: 0o700)
          File.chmod(0o700, @scratch_root)
        end
        dir = Dir.mktmpdir("hive-digest-evidence-", @scratch_root)
        File.chmod(0o700, dir)
        dir
      end

      def safe_component(value)
        ::Digest::SHA256.hexdigest(value.to_s)[0, 24]
      end
    end
  end
end
