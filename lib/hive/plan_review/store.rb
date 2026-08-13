require "digest"
require "fileutils"
require "json"
require "pathname"
require "hive/atomic_file"
require "hive/canonical_json"
require "hive/plan_review/record"
require "hive/secret_patterns"

module Hive
  module PlanReview
    class Store
      ROOT_BASENAME = "plan-review".freeze
      CURRENT_BASENAME = "current.json".freeze
      MAX_JSON_BYTES = 2 * 1024 * 1024
      SAFE_SEGMENT = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}\z/

      attr_reader :task_folder, :root, :current_path

      def initialize(task_folder:)
        @task_folder = File.expand_path(task_folder)
        @root = File.join(@task_folder, ROOT_BASENAME)
        @current_path = File.join(@root, CURRENT_BASENAME)
      end

      def create_review!(record)
        record = coerce_record(record, kind: "manifest")
        path = File.join(review_root(record.review_id), "manifest.json")
        if optional_lstat(path)
          existing = ensure_review!(record.review_id)
          comparable = ->(value) { value.to_h.reject { |key, _entry| key == "created_at" } }
          unless comparable.call(existing) == comparable.call(record)
            raise InvalidRecord, "immutable plan review manifest already exists with different identity"
          end
          return existing
        end
        write_immutable(path, canonical_json(record.to_h), json: true)
        record
      end

      def write_attempt!(review_id:, attempt_id:, plan_bytes:, result:, coverage:, route_receipt:)
        ensure_review!(review_id)
        safe_segment!(attempt_id, "attempt id")
        directory = File.join(review_root(review_id), "attempts", attempt_id)
        ensure_directory!(directory)
        {
          "input_plan" => write_immutable(
            File.join(directory, "input-plan.md"),
            Hive::SecretPatterns.redact(plan_bytes.to_s),
            json: false
          ),
          "result" => write_immutable(
            File.join(directory, "result.json"), canonical_json(sanitize(result)), json: true
          ),
          "coverage" => write_immutable(
            File.join(directory, "coverage.json"), canonical_json(sanitize(coverage)), json: true
          ),
          "route_receipt" => write_immutable(
            File.join(directory, "route-receipt.json"),
            canonical_json(sanitize(route_receipt)),
            json: true
          )
        }.freeze
      end

      def write_review_artifact!(review_id:, basename:, content:, json: false)
        ensure_review!(review_id)
        safe_segment!(basename, "artifact basename")
        bytes = json ? canonical_json(sanitize(content)) : Hive::SecretPatterns.redact(content.to_s)
        write_immutable(File.join(review_root(review_id), basename), bytes, json:)
      end

      def write_decision!(review_id:, target_fingerprint:, decision_id:, data:)
        ensure_review!(review_id)
        safe_segment!(target_fingerprint, "decision target")
        safe_segment!(decision_id, "decision id")
        path = File.join(
          review_root(review_id), "decisions", target_fingerprint, "#{decision_id}.json"
        )
        write_immutable(path, canonical_json(sanitize(data)), json: true)
      end

      def publish_current!(record, expected_version:)
        with_current_lock do
          observed = current(optional: true)
          verify_cas!(observed, expected_version)
          sanitized = coerce_record(sanitize(coerce_record(record, kind: "projection").to_h),
                                    kind: "projection")
          next_version = observed ? observed.version + 1 : 1
          unless sanitized.version == next_version
            raise StaleObservation,
                  "projection version #{sanitized.version} does not follow #{observed&.version || 0}"
          end
          verify_lineage!(observed, sanitized)
          sanitized["artifacts"].each_value { |reference| validate_reference!(reference) }

          Hive::AtomicFile.write(current_path, canonical_json(sanitized.to_h), mode: 0o600)
          File.chmod(0o600, current_path)
          Hive::AtomicFile.fsync_directory(root)
          sanitized
        end
      end

      def current(optional: false)
        validate_regular_file!(current_path, "current projection")
        bytes = File.binread(current_path, MAX_JSON_BYTES + 1)
        raise InvalidRecord, "current projection exceeds the size limit" if bytes.bytesize > MAX_JSON_BYTES

        Record.new(JSON.parse(bytes))
      rescue Errno::ENOENT
        return nil if optional

        raise InvalidRecord, "plan review current projection is missing"
      rescue JSON::ParserError => e
        raise InvalidRecord, "plan review current projection is invalid JSON: #{e.message}"
      end

      # Authority-bearing readers use this accessor so a syntactically valid
      # current.json cannot authorize execution while one of the artifacts it
      # names has been removed, replaced, or edited in place.
      def current_validated(optional: false)
        record = current(optional:)
        return nil unless record

        record["artifacts"].each_value { |reference| validate_reference!(reference) }
        record
      end

      def read_reference(reference)
        validate_reference!(reference)
        path = reference_path(reference.fetch("path"))
        File.binread(path)
      end

      # Serialize the full observe/dispatch/publish lifecycle, not only the
      # current.json CAS write. A waiter re-reads the winner's route after the
      # lock and coalesces instead of spawning a duplicate reviewer.
      def with_orchestration_lock
        ensure_directory!(root)
        path = File.join(root, ".orchestrator.lock")
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      private

      def coerce_record(record, kind:)
        value = record.is_a?(Record) ? record : Record.new(record)
        raise InvalidRecord, "expected #{kind} record; got #{value.kind}" unless value.kind == kind

        value
      end

      def review_root(review_id)
        safe_segment!(review_id, "review id")
        File.join(root, "reviews", review_id)
      end

      def ensure_review!(review_id)
        path = File.join(review_root(review_id), "manifest.json")
        validate_regular_file!(path, "review manifest")
        Record.new(JSON.parse(File.binread(path)))
      rescue JSON::ParserError => e
        raise InvalidRecord, "review manifest is invalid JSON: #{e.message}"
      end

      def write_immutable(path, bytes, json:)
        bytes = bytes.to_s
        if json && bytes.bytesize > MAX_JSON_BYTES
          raise InvalidRecord, "plan review JSON artifact exceeds the size limit"
        end
        ensure_directory!(File.dirname(path))
        if (status = optional_lstat(path))
          validate_regular_file!(path, "plan review artifact", status:)
          existing = File.binread(path)
          return reference_for(path, existing) if existing == bytes

          raise InvalidRecord, "immutable plan review artifact already exists with different content"
        end
        Hive::AtomicFile.write(path, bytes, mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        reference_for(path, bytes)
      rescue SystemCallError, IOError => e
        raise InvalidRecord, "plan review artifact could not be written: #{e.message}"
      end

      def reference_for(path, bytes)
        {
          "path" => Pathname.new(path).relative_path_from(Pathname.new(root)).to_s,
          "sha256" => Digest::SHA256.hexdigest(bytes),
          "bytes" => bytes.bytesize
        }.freeze
      end

      def validate_reference!(reference)
        unless reference.is_a?(Hash) && reference.keys.map(&:to_s).sort == %w[bytes path sha256]
          raise InvalidRecord, "invalid plan review artifact reference"
        end
        path = reference_path(reference.fetch("path"))
        validate_regular_file!(path, "referenced artifact")
        stat = File.stat(path)
        unless stat.size == reference.fetch("bytes") &&
               Digest::SHA256.file(path).hexdigest == reference.fetch("sha256")
          raise InvalidRecord, "plan review artifact hash or size mismatch"
        end
        true
      rescue KeyError, TypeError
        raise InvalidRecord, "invalid plan review artifact reference"
      end

      def reference_path(relative)
        value = relative.to_s.tr("\\", "/")
        if value.empty? || value.start_with?("/") || value.include?("\0") ||
           value.split("/").any? { |segment| segment.empty? || segment == "." || segment == ".." }
          raise InvalidRecord, "plan review artifact path is unsafe"
        end
        path = File.expand_path(value, root)
        unless path.start_with?("#{root}#{File::SEPARATOR}")
          raise InvalidRecord, "plan review artifact path escapes its root"
        end
        path
      end

      def verify_cas!(observed, expected_version)
        if expected_version.nil?
          raise StaleObservation, "plan review projection already exists" if observed
        elsif !observed || observed.version != expected_version
          raise StaleObservation,
                "plan review projection changed (expected version #{expected_version}, " \
                "observed #{observed&.version.inspect})"
        end
      end

      def verify_lineage!(observed, candidate)
        return unless observed

        if candidate.review_id == observed.review_id
          %w[task_id task_generation plan_digest policy_fingerprint created_at].each do |key|
            next if candidate[key] == observed[key]

            raise StaleObservation, "current review immutable identity changed: #{key}"
          end
          return
        end
        return if candidate.prior_review_id == observed.review_id

        raise StaleObservation, "new plan review does not link to the current review"
      end

      def with_current_lock
        ensure_directory!(root)
        lock_path = File.join(root, ".current.lock")
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def ensure_directory!(path)
        expanded = File.expand_path(path)
        unless expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}") ||
               expanded == task_folder
          raise InvalidRecord, "plan review directory escapes the task"
        end
        relative = if expanded == root
          []
        else
          Pathname.new(expanded).relative_path_from(Pathname.new(root)).each_filename.to_a
        end
        cursor = root
        if expanded == root
          if (status = optional_lstat(root))
            validate_directory_status!(root, status)
          else
            FileUtils.mkdir_p(root, mode: 0o700)
          end
          File.chmod(0o700, root)
          return root
        end
        ensure_directory!(root)
        relative.each do |segment|
          cursor = File.join(cursor, segment)
          if (status = optional_lstat(cursor))
            validate_directory_status!(cursor, status)
          else
            Dir.mkdir(cursor, 0o700)
          end
          File.chmod(0o700, cursor)
        end
        expanded
      rescue SystemCallError, IOError => e
        raise InvalidRecord, "plan review directory is unavailable: #{e.message}"
      end

      def validate_directory_status!(path, status)
        raise InvalidRecord, "plan review directory #{path} is a symlink" if status.symlink?
        raise InvalidRecord, "plan review path #{path} is not a directory" unless status.directory?
      end

      def validate_regular_file!(path, label, status: optional_lstat(path))
        raise Errno::ENOENT, path unless status
        raise InvalidRecord, "#{label} is a symlink" if status.symlink?
        raise InvalidRecord, "#{label} is not a regular file" unless status.file?
      end

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def safe_segment!(value, label)
        return value if value.to_s.match?(SAFE_SEGMENT)

        raise InvalidRecord, "#{label} is unsafe"
      end

      def sanitize(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s, sanitize(child) ] }
        when Array then value.map { |child| sanitize(child) }
        when String then Hive::SecretPatterns.redact(value)
        when Symbol then value.to_s
        else value
        end
      end

      def canonical_json(value)
        "#{Hive::CanonicalJSON.generate(value)}\n"
      end
    end
  end
end
