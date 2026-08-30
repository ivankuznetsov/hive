require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/artifacts/outcome_evidence/contract"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/proof"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Append-only authorizations for returning a reviewed implementation to
      # 4-execute. The current evidence pointer remains the semantic source;
      # these two bounded receipts prevent a review/rework loop from running
      # forever and carry the exact reviewer feedback into the implementer.
      class Rework
        SCHEMA = "hive-outcome-evidence-rework".freeze
        VERSION = 1
        MAX_REWORKS = 2
        MAX_BYTES = 256 * 1024
        FILE_NAME = /\Arework-(?<sequence>[0-9]{2})\.json\z/

        def initialize(task:, project:, clock: -> { Time.now.utc })
          @task = task
          @project = project.to_s
          @clock = clock
        end

        def records
          names = receipt_names
          names.map.with_index(1) do |name, expected_sequence|
            match = FILE_NAME.match(name)
            unless match && match[:sequence].to_i == expected_sequence
              raise StoreError, "outcome-evidence rework receipt sequence is invalid"
            end

            read_receipt(File.join(root, name), expected_sequence: expected_sequence)
          end
        end

        def record!(package:, expected_generation:, expected_digest:)
          source = rework_package!(package)
          generation = valid_digest!(expected_generation, "expected generation")
          digest = valid_digest!(expected_digest, "expected recovery digest")
          unless source.fetch("generation") == generation &&
                 source.fetch("recovery_digest") == digest
            raise StoreError, "outcome-evidence rework observation is stale"
          end

          existing = records
          matching = existing.find do |receipt|
            receipt.values_at("generation", "recovery_digest") == [ generation, digest ]
          end
          return matching if matching
          if existing.length >= MAX_REWORKS
            raise StoreError, "outcome-evidence implementation rework limit is exhausted"
          end

          sequence = existing.length + 1
          document = {
            "schema" => SCHEMA,
            "schema_version" => VERSION,
            "task" => @task.slug.to_s,
            "project" => @project,
            "sequence" => sequence,
            "generation" => generation,
            "recovery_digest" => digest,
            "implementation_base" => source.fetch("implementation_base"),
            "implementation_head" => source.fetch("implementation_head"),
            "failed_targets" => source.fetch("failed_targets"),
            "reviewer_reasons" => source.fetch("reviewer_reasons"),
            "recorded_at" => iso_time(@clock.call)
          }
          write_once(receipt_path(sequence), document)
        end

        def execution_context(package:, records: self.records)
          receipts = records
          # Protect the complete bounded namespace, including the one missing
          # future slot, so an implementer cannot pre-authorize another cycle.
          ensure_root!
          paths = (1..MAX_REWORKS).map { |sequence| relative_receipt_path(sequence) }
          return { "feedback" => nil, "protected_paths" => paths.sort } if receipts.empty?

          pointer = package.to_h.fetch("current").to_h
          unless pointer["status"].to_s == "rework"
            return { "feedback" => nil, "protected_paths" => paths.sort }
          end

          source = rework_package!(package)
          receipt = receipts.last
          unless receipt.values_at("generation", "recovery_digest") ==
                 source.values_at("generation", "recovery_digest")
            raise StoreError, "active outcome-evidence rework lacks its exact authorization"
          end
          feedback = {
            "reviewed_generation" => receipt.fetch("generation"),
            "implementation_base" => receipt.fetch("implementation_base"),
            "implementation_head" => receipt.fetch("implementation_head"),
            "failed_targets" => receipt.fetch("failed_targets"),
            "reviewer_reasons" => receipt.fetch("reviewer_reasons")
          }
          generation = receipt.fetch("generation")
          package_paths = [
            "outcome-evidence/current.json",
            "outcome-evidence/generations/#{generation}/implementation.diff",
            "outcome-evidence/generations/#{generation}/requirement.json"
          ]
          Array(pointer.fetch("attempts")).each do |attempt|
            id = valid_id!(attempt.to_h.fetch("attempt_id"), "attempt ID")
            package_paths << "outcome-evidence/generations/#{generation}/attempts/#{id}.json"
          end
          package_paths.concat(protected_evidence_paths(package))
          { "feedback" => feedback, "protected_paths" => (paths + package_paths).uniq.sort }
        rescue KeyError, NoMethodError, ResolutionError => e
          raise StoreError, "outcome-evidence rework package is malformed: #{e.message}"
        end

        private

        def rework_package!(package)
          package = package.to_h
          pointer = package.fetch("current").to_h
          requirement = package.fetch("requirement").to_h
          unless pointer.values_at("status", "reason") ==
                 [ "rework", "implementation_rework" ]
            raise StoreError, "current outcome evidence does not require implementation rework"
          end
          generation = valid_digest!(pointer.fetch("generation"), "rework generation")
          unless requirement.fetch("generation").to_s == generation
            raise StoreError, "outcome-evidence rework requirement generation is inconsistent"
          end
          implementation = requirement.fetch("implementation").to_h
          {
            "generation" => generation,
            "recovery_digest" => valid_digest!(
              pointer.fetch("recovery_digest"), "rework recovery digest"
            ),
            "implementation_base" => valid_oid!(
              implementation.fetch("implementation_base"), "implementation base"
            ),
            "implementation_head" => valid_oid!(
              implementation.fetch("implementation_head"), "implementation head"
            ),
            "failed_targets" => canonical_targets(pointer.fetch("failed_targets")),
            "reviewer_reasons" => canonical_reasons(pointer.fetch("reviewer_reasons"))
          }
        rescue KeyError, NoMethodError => e
          raise StoreError, "outcome-evidence rework package is malformed: #{e.message}"
        end

        def receipt_names
          stat = File.lstat(root)
          unless stat.directory? && !stat.symlink?
            raise StoreError, "outcome-evidence rework receipts must be a directory"
          end
          allowed = (1..MAX_REWORKS).map { |sequence| File.basename(receipt_path(sequence)) }
          Dir.children(root).select { |name| allowed.include?(name) }.sort
        rescue Errno::ENOENT
          []
        end

        def read_receipt(path, expected_sequence:)
          source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            raise StoreError, "outcome-evidence rework receipt must be a regular file" unless file.stat.file?

            value = file.read(MAX_BYTES + 1)
            raise StoreError, "outcome-evidence rework receipt is oversized" if value.bytesize > MAX_BYTES

            value
          end
          value = JSON.parse(
            source, object_class: Document::StrictHash, allow_duplicate_key: false
          )
          expected_keys = %w[
            failed_targets generation implementation_base implementation_head project
            recorded_at recovery_digest reviewer_reasons schema schema_version sequence task
          ]
          unless value.is_a?(Hash) && value.keys.sort == expected_keys &&
                 value["schema"] == SCHEMA && value["schema_version"] == VERSION &&
                 value["task"] == @task.slug.to_s && value["project"] == @project &&
                 value["sequence"] == expected_sequence
            raise StoreError, "outcome-evidence rework receipt is malformed"
          end
          valid_digest!(value.fetch("generation"), "rework generation")
          valid_digest!(value.fetch("recovery_digest"), "rework recovery digest")
          valid_oid!(value.fetch("implementation_base"), "implementation base")
          valid_oid!(value.fetch("implementation_head"), "implementation head")
          canonical_targets(value.fetch("failed_targets"))
          canonical_reasons(value.fetch("reviewer_reasons"))
          Time.iso8601(value.fetch("recorded_at"))
          value
        rescue Errno::ENOENT, Errno::ELOOP
          raise StoreError, "outcome-evidence rework receipt must be a regular file"
        rescue JSON::ParserError, ArgumentError, KeyError, TypeError => e
          raise StoreError, "outcome-evidence rework receipt is malformed: #{e.message}"
        end

        def write_once(path, document)
          source = JSON.generate(document) << "\n"
          raise StoreError, "outcome-evidence rework receipt is oversized" if source.bytesize > MAX_BYTES

          ensure_root!
          begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
              file.write(source)
              file.flush
              file.fsync
            end
            Hive::AtomicFile.fsync_directory(root)
          rescue Errno::EEXIST
            existing = read_receipt(path, expected_sequence: document.fetch("sequence"))
            raise StoreError, "outcome-evidence rework receipt is append-only and already differs" unless existing == document
          end
          read_receipt(path, expected_sequence: document.fetch("sequence"))
        end

        def ensure_root!
          [ File.dirname(root), root ].each do |directory|
            begin
              stat = File.lstat(directory)
              raise StoreError, "outcome-evidence rework directory must not be a symlink" if stat.symlink?
              raise StoreError, "outcome-evidence rework directory is invalid" unless stat.directory?
            rescue Errno::ENOENT
              FileUtils.mkdir_p(directory, mode: 0o700)
            end
            FileUtils.chmod(0o700, directory)
          end
        end

        def canonical_targets(value)
          values = Array(value).map { |entry| valid_id!(entry, "failed target") }
          unless values.any? && values.uniq == values
            raise StoreError, "outcome-evidence rework failed targets are invalid"
          end
          values.sort
        end

        def canonical_reasons(value)
          values = Array(value).map do |entry|
            text = entry.to_s.strip
            unless text.bytesize.between?(1, Contract::MAX_STATEMENT_BYTES)
              raise StoreError, "outcome-evidence rework reviewer reason is invalid"
            end
            Contract.secret_free!(text, "outcome-evidence rework reviewer reason")
          end
          unless values.any? && values.uniq == values
            raise StoreError, "outcome-evidence rework reviewer reasons are invalid"
          end
          values
        end

        def protected_evidence_paths(package)
          Array(package.to_h.fetch("attempts")).flat_map do |attempt|
            Array(attempt.to_h.fetch("evidence")).flat_map do |entry|
              evidence = entry.to_h
              paths = Array(evidence.fetch("representations")).map do |representation|
                Identity.validate_changed_path!(representation.to_h.fetch("path"))
              end
              manifest = evidence.fetch("source").to_h["manifest_path"]
              paths << Identity.validate_changed_path!(manifest) if manifest
              paths
            end
          end
        end

        def valid_id!(value, label)
          text = value.to_s
          raise StoreError, "#{label} is invalid" unless text.match?(Proof::SAFE_CLAIM)

          text
        end

        def valid_digest!(value, label)
          text = value.to_s.downcase
          raise StoreError, "#{label} is invalid" unless text.match?(Proof::DIGEST)

          text
        end

        def valid_oid!(value, label)
          text = value.to_s.downcase
          raise StoreError, "#{label} is invalid" unless text.match?(/\A[0-9a-f]{40,64}\z/)

          text
        end

        def root
          File.join(@task.folder, "outcome-evidence", "reworks")
        end

        def receipt_path(sequence)
          File.join(root, format("rework-%02d.json", sequence))
        end

        def relative_receipt_path(sequence)
          File.join("outcome-evidence", "reworks", format("rework-%02d.json", sequence))
        end

        def iso_time(value)
          value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
        end
      end
    end
  end
end
