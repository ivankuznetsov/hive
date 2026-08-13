require "digest"
require "fileutils"
require "time"
require "hive/atomic_file"
require "hive/attempts/context"
require "hive/attempts/store"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/identity"
require "hive/artifacts/outcome_evidence/legacy_capture_reader"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Immutable requirements and attempts with one atomic, replaceable
      # current pointer. Publishing is the only operation that establishes an
      # accepted generation; a retained legacy capture never enters this path.
      class Store
        ROOT = "outcome-evidence".freeze
        MAX_DOCUMENT_BYTES = 256 * 1024
        SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        SCHEMAS = {
          requirement: "hive-outcome-evidence-requirement",
          attempt: "hive-outcome-evidence-attempt",
          current: "hive-outcome-evidence-current"
        }.freeze

        def initialize(task:, project:, clock: -> { Time.now.utc }, controller_binding: nil,
                       attempt_store: nil)
          @task = task
          @project = project.to_s
          @clock = clock
          @attempt_store = attempt_store
          @controller_binding = controller_binding
        end

        def open_generation!(identity:)
          canonical = canonical_identity(identity)
          binding = controller_binding
          task_generation = binding.fetch("task_generation").to_s
          recovery_epoch = binding.fetch("recovery_epoch")
          epoch = Integer(recovery_epoch)
          raise StoreError, "recovery epoch must be non-negative" if epoch.negative?
          task_generation = task_generation.to_s
          raise StoreError, "controller task generation is required" if task_generation.empty?

          generation = generation_for(canonical, task_generation, epoch)
          document = {
            "schema" => SCHEMAS.fetch(:requirement),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "task_generation" => task_generation,
            "recovery_epoch" => epoch,
            "generation" => generation,
            "requirement" => "outcome_evidence_required",
            "implementation" => canonical,
            "created_at" => iso_time(@clock.call)
          }
          write_once(
            requirement_path(generation), document,
            schema: SCHEMAS.fetch(:requirement), label: "outcome-evidence requirement"
          )
        rescue ArgumentError, TypeError => e
          raise StoreError, "recovery epoch is invalid: #{e.message}"
        end

        def append_attempt!(generation:, attempt_id:, status:, evidence:, diagnostic: nil)
          generation = validate_digest!(generation, "generation")
          attempt_id = validate_id!(attempt_id, "attempt ID")
          requirement = read_document(
            requirement_path(generation), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          unless requirement.fetch("generation") == generation
            raise StoreError, "requirement generation contradicts its append-only path"
          end

          entries = Array(evidence).map { |entry| canonical_evidence(entry) }
          status = status.to_s
          if status == "accepted" && entries.empty?
            raise StoreError, "accepted outcome evidence requires at least one evidence entry"
          end
          if status == "accepted" && entries.any? { |entry| entry["kind"] == "legacy_capture" }
            raise StoreError, "legacy capture cannot establish accepted outcome evidence"
          end
          diagnostic = diagnostic&.to_s
          if status == "rejected" && diagnostic.to_s.empty?
            raise StoreError, "rejected outcome evidence requires a diagnostic"
          end

          document = {
            "schema" => SCHEMAS.fetch(:attempt),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "generation" => generation,
            "attempt_id" => attempt_id,
            "status" => status,
            "evidence" => entries,
            "diagnostic" => diagnostic,
            "recorded_at" => iso_time(@clock.call)
          }
          write_once(
            attempt_path(generation, attempt_id), document,
            schema: SCHEMAS.fetch(:attempt), label: "outcome-evidence attempt"
          )
        end

        def publish_current!(generation:, attempt_id:)
          generation = validate_digest!(generation, "generation")
          attempt_id = validate_id!(attempt_id, "attempt ID")
          requirement_file = requirement_path(generation)
          attempt_file = attempt_path(generation, attempt_id)
          requirement = read_document(
            requirement_file, schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          attempt = read_document(
            attempt_file, schema: SCHEMAS.fetch(:attempt),
            label: "outcome-evidence attempt"
          )
          validate_publication!(requirement, attempt, generation, attempt_id)
          validate_retained_evidence!(attempt)

          document = {
            "schema" => SCHEMAS.fetch(:current),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "generation" => generation,
            "attempt_id" => attempt_id,
            "requirement_sha256" => Digest::SHA256.file(requirement_file).hexdigest,
            "attempt_sha256" => Digest::SHA256.file(attempt_file).hexdigest,
            "published_at" => iso_time(@clock.call)
          }
          source = Document.generate(
            document, schema: SCHEMAS.fetch(:current), label: "outcome-evidence current pointer"
          )
          ensure_store_directories!
          reject_symlink!(current_path, "current pointer")
          Hive::AtomicFile.write(current_path, source, mode: 0o600)
          Hive::AtomicFile.fsync_directory(root)
          read_current!
        end

        def current
          read_current!
        rescue StoreError, SystemCallError
          nil
        end

        def accepted?(generation: nil)
          pointer = read_current!
          return false if generation && pointer.fetch("generation") != generation.to_s

          requirement_file = requirement_path(pointer.fetch("generation"))
          attempt_file = attempt_path(
            pointer.fetch("generation"), pointer.fetch("attempt_id")
          )
          return false unless secure_file_digest(requirement_file) == pointer.fetch("requirement_sha256")
          return false unless secure_file_digest(attempt_file) == pointer.fetch("attempt_sha256")

          requirement = read_document(
            requirement_file, schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          attempt = read_document(
            attempt_file, schema: SCHEMAS.fetch(:attempt),
            label: "outcome-evidence attempt"
          )
          validate_publication!(
            requirement, attempt, pointer.fetch("generation"), pointer.fetch("attempt_id")
          )
          validate_retained_evidence!(attempt)
          true
        rescue StoreError, SystemCallError
          false
        end

        def legacy_capture
          LegacyCaptureReader.new(@task.folder).read
        end

        private

        def root
          File.join(@task.folder, ROOT)
        end

        def generations_root
          File.join(root, "generations")
        end

        def generation_root(generation)
          File.join(generations_root, generation)
        end

        def requirement_path(generation)
          File.join(generation_root(generation), "requirement.json")
        end

        def attempt_path(generation, attempt_id)
          File.join(generation_root(generation), "attempts", "#{attempt_id}.json")
        end

        def current_path
          File.join(root, "current.json")
        end

        def ensure_store_directories!
          [ root, generations_root ].each do |directory|
            reject_symlink!(directory, "outcome-evidence directory")
            FileUtils.mkdir_p(directory, mode: 0o700)
            stat = File.lstat(directory)
            raise StoreError, "outcome-evidence directory is not a directory" unless stat.directory?
          end
        end

        def ensure_generation_directories!(generation)
          ensure_store_directories!
          [ generation_root(generation), File.join(generation_root(generation), "attempts") ].each do |directory|
            reject_symlink!(directory, "outcome-evidence generation directory")
            FileUtils.mkdir_p(directory, mode: 0o700)
            stat = File.lstat(directory)
            raise StoreError, "outcome-evidence generation directory is not a directory" unless stat.directory?
          end
        end

        def canonical_identity(identity)
          data = identity.to_h.transform_keys(&:to_s)
          required = %w[
            branch implementation_base merge_base implementation_head
            changed_paths changed_paths_digest
          ]
          missing = required.reject { |key| data.key?(key) && !data[key].nil? }
          raise StoreError, "implementation identity is missing: #{missing.join(', ')}" unless missing.empty?

          paths = Array(data.fetch("changed_paths")).map do |path|
            Identity.validate_changed_path!(path)
          end
          unless paths == paths.uniq.sort && !paths.empty?
            raise StoreError, "implementation changed paths must be nonempty, unique, and sorted"
          end
          expected_digest = Digest::SHA256.hexdigest(paths.join("\0"))
          unless data.fetch("changed_paths_digest").to_s == expected_digest
            raise StoreError, "implementation changed-path digest is invalid"
          end

          base = validate_oid!(data.fetch("implementation_base"), "implementation base")
          merge_base = validate_oid!(data.fetch("merge_base"), "merge base")
          unless merge_base == base
            raise StoreError, "implementation merge base must equal the frozen controller base"
          end
          repository = data["repository"]&.to_s
          {
            "repository" => repository.to_s.empty? ? nil : repository,
            "branch" => data.fetch("branch").to_s,
            "implementation_base" => base,
            "merge_base" => merge_base,
            "implementation_head" => validate_oid!(
              data.fetch("implementation_head"), "implementation head"
            ),
            "changed_paths" => paths,
            "changed_paths_digest" => expected_digest
          }
        rescue ResolutionError => e
          raise StoreError, e.message
        end

        def canonical_evidence(value)
          unless value.respond_to?(:to_h)
            raise StoreError, "outcome evidence entries must be objects"
          end
          entry = value.to_h.transform_keys(&:to_s)
          allowed = %w[kind summary path sha256 bytes]
          unknown = entry.keys - allowed
          raise StoreError, "outcome evidence contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?

          result = {
            "kind" => entry.fetch("kind").to_s,
            "summary" => entry.fetch("summary").to_s
          }
          if entry.key?("path")
            result["path"] = Identity.validate_changed_path!(entry.fetch("path"))
          end
          result["sha256"] = validate_digest!(entry["sha256"], "evidence SHA-256") if entry.key?("sha256")
          if entry.key?("bytes")
            bytes = Integer(entry["bytes"])
            raise StoreError, "evidence bytes must be positive" unless bytes.positive?
            result["bytes"] = bytes
          end
          result
        rescue KeyError => e
          raise StoreError, "outcome evidence is missing #{e.key}"
        rescue ArgumentError, TypeError, ResolutionError => e
          raise StoreError, e.message
        end

        def generation_for(identity, task_generation, recovery_epoch)
          Digest::SHA256.hexdigest(
            [
              "hive-outcome-evidence-generation-v1", @project, @task.slug.to_s,
              task_generation, recovery_epoch.to_s,
              identity.fetch("implementation_base"), identity.fetch("implementation_head"),
              identity.fetch("changed_paths_digest")
            ].join("\0")
          )
        end

        def controller_binding
          return @controller_binding.call if @controller_binding

          context = Hive::Attempts::Context.current
          unless context
            raise StoreError,
                  "outcome evidence requires a controller-owned durable attempt context"
          end
          store = @attempt_store || Hive::Attempts::Store.new(create_directories: false)
          record = store.fetch(context.attempt_id)
          unless record && record["project"] == @project &&
                 record["task_slug"] == @task.slug.to_s &&
                 record["intended_stage"] == "7-artifacts" &&
                 record.ownership_generation == context.ownership_generation
            raise StoreError, "durable attempt does not own this artifacts generation"
          end

          {
            "task_generation" => record.ownership_generation,
            "recovery_epoch" => record["retry_charge"]
          }
        end

        def write_once(path, document, schema:, label:)
          source = Document.generate(document, schema: schema, label: label)
          raise StoreError, "#{label} exceeds #{MAX_DOCUMENT_BYTES} bytes" if source.bytesize > MAX_DOCUMENT_BYTES
          generation = document.fetch("generation")
          ensure_generation_directories!(generation)
          begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
              file.write(source)
              file.flush
              file.fsync
            end
            Hive::AtomicFile.fsync_directory(File.dirname(path))
          rescue Errno::EEXIST
            existing = read_document(path, schema: schema, label: label)
            raise StoreError, "#{label} is append-only and already differs" unless existing == document
          rescue Errno::ELOOP
            raise StoreError, "#{label} must be a regular file, not a symlink"
          end
          read_document(path, schema: schema, label: label)
        end

        def read_current!
          read_document(
            current_path, schema: SCHEMAS.fetch(:current),
            label: "outcome-evidence current pointer"
          )
        end

        def read_document(path, schema:, label:)
          source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            raise StoreError, "#{label} must be a regular file" unless file.stat.file?

            value = file.read(MAX_DOCUMENT_BYTES + 1)
            raise StoreError, "#{label} exceeds #{MAX_DOCUMENT_BYTES} bytes" if value.bytesize > MAX_DOCUMENT_BYTES

            value
          end
          Document.parse(source, schema: schema, label: label)
        rescue Errno::ENOENT
          raise StoreError, "#{label} is missing"
        rescue Errno::ELOOP
          raise StoreError, "#{label} must be a regular file, not a symlink"
        end

        def validate_publication!(requirement, attempt, generation, attempt_id)
          unless requirement.values_at("task", "project", "generation") ==
                 [ @task.slug.to_s, @project, generation ]
            raise StoreError, "requirement contradicts the current task generation"
          end
          unless attempt.values_at("task", "project", "generation", "attempt_id", "status") ==
                 [ @task.slug.to_s, @project, generation, attempt_id, "accepted" ]
            raise StoreError, "attempt cannot establish accepted outcome evidence"
          end
          if attempt.fetch("evidence").any? { |entry| entry.fetch("kind") == "legacy_capture" }
            raise StoreError, "legacy capture cannot establish accepted outcome evidence"
          end
        end

        def validate_retained_evidence!(attempt)
          attempt.fetch("evidence").each do |entry|
            next unless entry["path"]

            path = Identity.validate_changed_path!(entry.fetch("path"))
            candidate = File.join(@task.folder, path)
            stat = File.lstat(candidate)
            unless stat.file? && !stat.symlink?
              raise StoreError, "retained evidence #{path.inspect} must be a regular file"
            end
            real_task = File.realpath(@task.folder)
            real_candidate = File.realpath(candidate)
            unless real_candidate.start_with?("#{real_task}#{File::SEPARATOR}")
              raise StoreError, "retained evidence #{path.inspect} escapes the task folder"
            end
            if entry["bytes"] && entry["bytes"] != stat.size
              raise StoreError, "retained evidence #{path.inspect} byte size changed"
            end
            if entry["sha256"] && entry["sha256"] != Digest::SHA256.file(candidate).hexdigest
              raise StoreError, "retained evidence #{path.inspect} digest changed"
            end
          rescue Errno::ENOENT, Errno::ELOOP
            raise StoreError, "retained evidence #{path.inspect} is unavailable"
          end
        end

        def secure_file_digest(path)
          File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            raise StoreError, "outcome-evidence document must be regular" unless file.stat.file?

            digest = Digest::SHA256.new
            total = 0
            while (chunk = file.read(16 * 1024))
              total += chunk.bytesize
              raise StoreError, "outcome-evidence document exceeds #{MAX_DOCUMENT_BYTES} bytes" if total > MAX_DOCUMENT_BYTES
              digest << chunk
            end
            digest.hexdigest
          end
        rescue Errno::ENOENT, Errno::ELOOP
          nil
        end

        def reject_symlink!(path, label)
          stat = File.lstat(path)
          raise StoreError, "#{label} must not be a symlink" if stat.symlink?
        rescue Errno::ENOENT
          nil
        end

        def validate_oid!(value, label)
          oid = value.to_s.downcase
          raise StoreError, "#{label} is invalid" unless oid.match?(Identity::OID)

          oid
        end

        def validate_digest!(value, label)
          digest = value.to_s.downcase
          raise StoreError, "#{label} is invalid" unless digest.match?(DIGEST)

          digest
        end

        def validate_id!(value, label)
          id = value.to_s
          raise StoreError, "#{label} is unsafe" unless id.match?(SAFE_ID)

          id
        end

        def iso_time(value)
          value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
        end
      end
    end
  end
end
