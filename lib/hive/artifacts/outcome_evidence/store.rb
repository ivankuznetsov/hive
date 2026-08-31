require "digest"
require "fileutils"
require "pathname"
require "time"
require "hive/atomic_file"
require "hive/agent_git_gate"
require "hive/attempts/context"
require "hive/attempts/repository"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/contract"
require "hive/artifacts/outcome_evidence/identity"
require "hive/artifacts/outcome_evidence/legacy_capture_reader"
require "hive/artifacts/outcome_evidence/proof"
require "hive/artifacts/outcome_evidence/recovery"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Immutable requirements and attempts with one atomic, replaceable
      # current pointer. Publishing is the only operation that establishes an
      # accepted generation; a retained legacy capture never enters this path.
      class Store
        ROOT = "outcome-evidence".freeze
        MAX_DOCUMENT_BYTES = 256 * 1024
        MAX_DIFF_BYTES = 16 * 1024 * 1024
        SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
        DIGEST = Proof::DIGEST
        BLOCK_REASONS = %w[
          capability_blocked review_blocked recaptures_exhausted reworks_exhausted
        ].freeze
        REWORK_REASON = "implementation_rework".freeze
        SCHEMAS = {
          requirement: "hive-outcome-evidence-requirement",
          candidate: "hive-outcome-evidence-candidate",
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

        def open_generation!(identity:, claims:, exclusions:, inference:,
                             reviewer_capabilities: nil)
          canonical = canonical_identity(identity)
          binding = controller_binding
          task_generation = binding.fetch("task_generation").to_s
          recovery_epoch = binding.fetch("recovery_epoch")
          epoch = Integer(recovery_epoch)
          raise StoreError, "recovery epoch must be non-negative" if epoch.negative?
          task_generation = task_generation.to_s
          raise StoreError, "controller task generation is required" if task_generation.empty?

          generation = generation_for(canonical, task_generation, epoch)
          existing = existing_requirement(
            generation, canonical: canonical, task_generation: task_generation,
            recovery_epoch: epoch
          )
          return existing if existing

          semantic = Contract.requirement!(
            implementation: canonical, claims: claims,
            exclusions: exclusions, inference: inference
          )
          capabilities = canonical_reviewer_capabilities(
            reviewer_capabilities || {
              "proof_kinds" => Proof::KINDS, "temporal_video" => true
            }
          )
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
            "claims" => semantic.fetch("claims"),
            "exclusions" => semantic.fetch("exclusions"),
            "traceability" => semantic.fetch("traceability"),
            "inference" => semantic.fetch("inference"),
            "reviewer_capabilities" => capabilities,
            "created_at" => iso_time(@clock.call)
          }
          write_once(
            requirement_path(generation), document,
            schema: SCHEMAS.fetch(:requirement), label: "outcome-evidence requirement"
          )
        rescue ArgumentError, TypeError => e
          raise StoreError, "recovery epoch is invalid: #{e.message}"
        end

        def append_attempt!(generation:, attempt_id:, status:, evidence:, producer: nil,
                            review: nil, diagnostic: nil)
          generation = validate_digest!(generation, "generation")
          attempt_id = validate_id!(attempt_id, "attempt ID")
          requirement = read_document(
            requirement_path(generation), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          unless requirement.fetch("generation") == generation
            raise StoreError, "requirement generation contradicts its append-only path"
          end

          status = status.to_s
          raw_entries = Array(evidence)
          if status == "accepted" && raw_entries.any? do |entry|
               entry.respond_to?(:to_h) && entry.to_h.transform_keys(&:to_s)["kind"] == "legacy_capture"
             end
            raise StoreError, "legacy capture cannot establish accepted outcome evidence"
          end
          entries = raw_entries.map do |entry|
            Proof.admit!(
              entry, task_folder: @task.folder,
              expected_head: requirement.dig("implementation", "implementation_head")
            )
          end
          if status == "accepted" && entries.empty?
            raise StoreError, "accepted outcome evidence requires at least one evidence entry"
          end
          producer ||= {}
          review ||= {}
          canonical_review = Contract.review!(
            requirement: requirement, evidence: entries, producer: producer,
            reviewer: review["reviewer"] || review[:reviewer],
            output: {
              "review_scope_hashes" => review["review_scope_hashes"] || review[:review_scope_hashes],
              "verdicts" => review["verdicts"] || review[:verdicts]
            }
          )
          canonical_producer = canonical_review.delete("producer")
          expected_status = canonical_review.fetch("status")
          unless status == expected_status
            raise StoreError, "attempt status contradicts the independent semantic review"
          end
          diagnostic = diagnostic&.to_s
          if status != "accepted" && diagnostic.to_s.empty?
            raise StoreError, "non-accepted outcome evidence requires a diagnostic"
          end
          Contract.secret_free!(diagnostic, "outcome-evidence attempt diagnostic") if diagnostic

          document = {
            "schema" => SCHEMAS.fetch(:attempt),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "generation" => generation,
            "attempt_id" => attempt_id,
            "status" => status,
            "evidence" => entries,
            "producer" => canonical_producer,
            "review" => canonical_review,
            "diagnostic" => diagnostic,
            "recorded_at" => iso_time(@clock.call)
          }
          write_once(
            attempt_path(generation, attempt_id), document,
            schema: SCHEMAS.fetch(:attempt), label: "outcome-evidence attempt"
          )
        end

        def retain_candidate!(generation:, attempt_id:, evidence:, producer: nil)
          generation = validate_digest!(generation, "generation")
          attempt_id = validate_id!(attempt_id, "attempt ID")
          requirement = read_document(
            requirement_path(generation), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          ensure_generation_directories!(generation)
          retained_root = File.join(generation_root(generation), "retained")
          ensure_private_directory!(retained_root, "outcome-evidence retained directory")
          attempt_root = File.join(retained_root, attempt_id)
          begin
            Dir.mkdir(attempt_root, 0o700)
            attempt_root_created = true
          rescue Errno::EEXIST, Errno::ELOOP
            raise StoreError, "outcome-evidence attempt custody root already exists"
          end
          relative_attempt_root = Pathname.new(attempt_root)
            .relative_path_from(Pathname.new(@task.folder)).to_s
          entries = Array(evidence).map.with_index do |entry, index|
            Proof.materialize_producer!(
              entry, task_folder: @task.folder,
              expected_head: requirement.dig("implementation", "implementation_head"),
              destination_root: File.join(
                relative_attempt_root, format("entry-%02d", index + 1)
              )
            )
          end
          Hive::AtomicFile.fsync_directory(attempt_root)
          record_candidate!(
            generation: generation, attempt_id: attempt_id,
            evidence: entries, producer: producer
          ) if producer
          entries
        rescue StoreError, SystemCallError
          FileUtils.remove_entry_secure(attempt_root) if
            attempt_root_created && attempt_root && File.directory?(attempt_root)
          raise
        end

        def record_candidate!(generation:, attempt_id:, evidence:, producer:)
          generation = validate_digest!(generation, "generation")
          attempt_id = validate_id!(attempt_id, "attempt ID")
          requirement = requirement(generation: generation)
          entries = canonical_candidate_evidence!(
            requirement: requirement, generation: generation,
            attempt_id: attempt_id, evidence: evidence
          )
          canonical_producer = producer.to_h.transform_keys(&:to_s)
          canonical_producer["model"] ||= "provider-default"
          canonical_producer["effort"] ||= "default"
          document = {
            "schema" => SCHEMAS.fetch(:candidate),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "generation" => generation,
            "attempt_id" => attempt_id,
            "evidence" => entries,
            "producer" => canonical_producer,
            "recorded_at" => iso_time(@clock.call)
          }
          write_once(
            candidate_path(generation, attempt_id), document,
            schema: SCHEMAS.fetch(:candidate), label: "outcome-evidence candidate"
          )
        end

        def pending_candidate(generation:)
          generation = validate_digest!(generation, "generation")
          recorded = attempts(generation: generation).map { |attempt| attempt.fetch("attempt_id") }
          directory = File.join(generation_root(generation), "retained")
          candidates = Dir.children(directory).filter_map do |attempt_id|
            validate_id!(attempt_id, "attempt ID")
            next if recorded.include?(attempt_id)

            path = candidate_path(generation, attempt_id)
            next unless File.file?(path)

            candidate = read_document(
              path, schema: SCHEMAS.fetch(:candidate), label: "outcome-evidence candidate"
            )
            requirement = requirement(generation: generation)
            expected = [ @task.slug.to_s, @project, generation, attempt_id ]
            unless candidate.values_at("task", "project", "generation", "attempt_id") == expected
              raise StoreError, "outcome-evidence candidate contradicts its custody path"
            end
            canonical = canonical_candidate_evidence!(
              requirement: requirement, generation: generation,
              attempt_id: attempt_id, evidence: candidate.fetch("evidence")
            )
            unless canonical == candidate.fetch("evidence")
              raise StoreError, "retained outcome-evidence candidate is not canonical"
            end
            candidate
          end
          candidates.max_by { |candidate| candidate.fetch("recorded_at") }
        rescue Errno::ENOENT
          nil
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
          validate_retained_evidence!(requirement, attempt)
          history = attempts(generation: generation).map do |item|
            id = item.fetch("attempt_id")
            {
              "attempt_id" => id,
              "attempt_sha256" => secure_file_digest!(
                attempt_path(generation, id), "outcome-evidence attempt"
              )
            }
          end
          unless history.last&.fetch("attempt_id") == attempt_id
            raise StoreError, "accepted attempt must be the latest immutable attempt"
          end

          document = {
            "schema" => SCHEMAS.fetch(:current),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "status" => "accepted",
            "generation" => generation,
            "recovery_epoch" => requirement.fetch("recovery_epoch"),
            "attempt_id" => attempt_id,
            "requirement_sha256" => secure_file_digest!(
              requirement_file, "outcome-evidence requirement"
            ),
            "attempt_sha256" => secure_file_digest!(
              attempt_file, "outcome-evidence attempt"
            ),
            "attempts" => history,
            "attempt_count" => history.length,
            "reason" => nil,
            "failed_targets" => [],
            "reviewer_reasons" => [],
            "recovery_digest" => nil,
            "published_at" => iso_time(@clock.call)
          }
          publish_pointer!(document)
        end

        def publish_blocked!(generation:, reason:, failed_targets:, reviewer_reasons:,
                             attempt_ids:)
          reason = reason.to_s
          unless BLOCK_REASONS.include?(reason)
            raise StoreError, "outcome-evidence blocked reason is invalid"
          end
          publish_unaccepted!(
            generation: generation, status: "blocked", reason: reason,
            failed_targets: failed_targets, reviewer_reasons: reviewer_reasons,
            attempt_ids: attempt_ids
          )
        end

        def publish_rework!(generation:, failed_targets:, reviewer_reasons:, attempt_ids:)
          publish_unaccepted!(
            generation: generation, status: "rework", reason: REWORK_REASON,
            failed_targets: failed_targets, reviewer_reasons: reviewer_reasons,
            attempt_ids: attempt_ids
          )
        end

        def current
          read_current!
        rescue StoreError, SystemCallError
          nil
        end

        def accepted?(generation: nil)
          pointer = read_current!
          return false unless pointer.fetch("status") == "accepted"
          return false if generation && pointer.fetch("generation") != generation.to_s

          requirement_file = requirement_path(pointer.fetch("generation"))
          attempt_file = attempt_path(
            pointer.fetch("generation"), pointer.fetch("attempt_id")
          )
          return false unless secure_file_digest(requirement_file) == pointer.fetch("requirement_sha256")
          return false unless secure_file_digest(attempt_file) == pointer.fetch("attempt_sha256")
          return false unless valid_pointer_digests?(pointer)

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
          history = attempts(generation: pointer.fetch("generation"))
          return false unless history.map { |item| item.fetch("attempt_id") } ==
                              pointer.fetch("attempts").map { |item| item.fetch("attempt_id") }
          history.each { |item| validate_retained_evidence!(requirement, item) }
          true
        rescue StoreError, SystemCallError, ArgumentError, TypeError
          false
        end

        def accepted_for_identity?(identity)
          pointer = read_current!
          expected_generation = generation_for_identity(identity)
          return false unless pointer.fetch("generation") == expected_generation

          requirement = read_document(
            requirement_path(pointer.fetch("generation")), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          requirement.fetch("implementation") == canonical_identity(identity) &&
            accepted?(generation: pointer.fetch("generation"))
        rescue StoreError, SystemCallError, ArgumentError, TypeError
          false
        end

        def blocked_for_identity?(identity)
          unaccepted_for_identity?(identity, status: "blocked")
        end

        def rework_for_identity?(identity)
          unaccepted_for_identity?(identity, status: "rework")
        end

        def requirement_for_identity(identity)
          canonical = canonical_identity(identity)
          generation, task_generation, epoch = current_generation(canonical)
          existing_requirement(
            generation, canonical: canonical, task_generation: task_generation,
            recovery_epoch: epoch
          )
        rescue ArgumentError, TypeError
          raise StoreError, "recovery epoch is invalid"
        end

        # Materialize the exact frozen diff once so read-only inference and
        # review roles can inspect it without receiving shell or Git authority.
        def materialize_review_context!(identity:, source_root:)
          canonical = canonical_identity(identity)
          generation, = current_generation(canonical)
          result = Hive::AgentGitGate.read(
            source_root, :diff, max_stdout_bytes: MAX_DIFF_BYTES,
            base_oid: canonical.fetch("implementation_base"),
            head_oid: canonical.fetch("implementation_head")
          )
          unless result.success?
            raise StoreError, "exact implementation diff is unavailable or oversized"
          end

          path = File.join(generation_root(generation), "implementation.diff")
          write_once_bytes(path, result.stdout, generation: generation)
          {
            "path" => Pathname.new(path).relative_path_from(Pathname.new(@task.folder)).to_s,
            "sha256" => secure_file_digest!(
              path, "exact implementation diff", max_bytes: MAX_DIFF_BYTES
            ),
            "bytes" => File.size(path),
            "implementation_base" => canonical.fetch("implementation_base"),
            "implementation_head" => canonical.fetch("implementation_head")
          }
        rescue Hive::AgentGitGate::Error => e
          raise StoreError, "exact implementation diff is unavailable: #{e.message}"
        end

        def review_context_for_identity(identity)
          canonical = canonical_identity(identity)
          generation, = current_generation(canonical)
          path = File.join(generation_root(generation), "implementation.diff")
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink?
            raise StoreError, "exact implementation diff must be a regular file"
          end
          {
            "path" => Pathname.new(path).relative_path_from(Pathname.new(@task.folder)).to_s,
            "sha256" => secure_file_digest!(
              path, "exact implementation diff", max_bytes: MAX_DIFF_BYTES
            ),
            "bytes" => stat.size,
            "implementation_base" => canonical.fetch("implementation_base"),
            "implementation_head" => canonical.fetch("implementation_head")
          }
        rescue Errno::ENOENT, Errno::ELOOP
          nil
        end

        def attempts(generation:)
          generation = validate_digest!(generation, "generation")
          directory = File.join(generation_root(generation), "attempts")
          names = Dir.children(directory)
          if names.length > 3 || names.any? { |name| !name.end_with?(".json") }
            raise StoreError, "outcome-evidence attempt history is invalid"
          end
          names.sort.map do |name|
            id = name.delete_suffix(".json")
            validate_id!(id, "attempt ID")
            read_document(
              attempt_path(generation, id), schema: SCHEMAS.fetch(:attempt),
              label: "outcome-evidence attempt"
            )
          end
        rescue Errno::ENOENT
          []
        end

        def requirement(generation:)
          generation = validate_digest!(generation, "generation")
          read_document(
            requirement_path(generation), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
        end

        def legacy_capture
          LegacyCaptureReader.new(@task.folder).read
        end

        def package
          build_package(validate_representations: true)
        end

        # Query projection for Web and structured inspection. Immutable
        # requirement/attempt documents and their canonical structural contract
        # are still checked against the current pointer digests, but expensive
        # media decoding and OCR stay at write admission. Individual media
        # requests recheck only their selected representation's size and digest
        # before streaming.
        def package_metadata
          build_package(validate_representations: false)
        end

        private

        def publish_unaccepted!(generation:, status:, reason:, failed_targets:,
                                reviewer_reasons:, attempt_ids:)
          generation = validate_digest!(generation, "generation")
          requirement_file = requirement_path(generation)
          requirement = read_document(
            requirement_file, schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          ids = Array(attempt_ids).map { |value| validate_id!(value, "attempt ID") }
          if ids.uniq != ids || ids.length > 3
            raise StoreError, "unaccepted outcome evidence has invalid attempt history"
          end
          attempt_documents = ids.map do |attempt_id|
            path = attempt_path(generation, attempt_id)
            attempt = read_document(
              path, schema: SCHEMAS.fetch(:attempt), label: "outcome-evidence attempt"
            )
            unless attempt.values_at("task", "project", "generation", "attempt_id") ==
                   [ @task.slug.to_s, @project, generation, attempt_id ] &&
                   attempt.fetch("status") != "accepted"
              raise StoreError, "outcome-evidence pointer names a contradictory attempt"
            end
            attempt
          end
          if status == "rework" && attempt_documents.last&.fetch("status") != "rework"
            raise StoreError, "outcome-evidence rework pointer must name a latest rework attempt"
          end
          attempts = ids.map do |attempt_id|
            {
              "attempt_id" => attempt_id,
              "attempt_sha256" => secure_file_digest!(
                attempt_path(generation, attempt_id), "outcome-evidence attempt"
              )
            }
          end
          if reason != "capability_blocked" && attempts.empty?
            raise StoreError, "semantic review blocker requires an admitted attempt"
          end
          targets = Array(failed_targets).map do |target_id|
            validate_claim_id!(target_id, "failed review target ID")
          end.uniq.sort
          rationales = Array(reviewer_reasons).map do |value|
            text = value.to_s.strip
            unless text.bytesize.between?(1, Contract::MAX_STATEMENT_BYTES)
              raise StoreError, "reviewer blocker reason is empty or oversized"
            end
            Contract.secret_free!(text, "reviewer blocker reason")
          end.uniq
          unless reason == "capability_blocked" || targets.any?
            raise StoreError, "semantic review blocker requires failed targets"
          end
          digest = recovery_digest(
            generation: generation, reason: reason, attempts: attempts,
            failed_targets: targets, reviewer_reasons: rationales
          )
          last = attempts.last
          publish_pointer!(
            "schema" => SCHEMAS.fetch(:current),
            "schema_version" => 1,
            "task" => @task.slug.to_s,
            "project" => @project,
            "status" => status,
            "generation" => generation,
            "recovery_epoch" => requirement.fetch("recovery_epoch"),
            "attempt_id" => last&.fetch("attempt_id"),
            "requirement_sha256" => secure_file_digest!(
              requirement_file, "outcome-evidence requirement"
            ),
            "attempt_sha256" => last&.fetch("attempt_sha256"),
            "attempts" => attempts,
            "attempt_count" => attempts.length,
            "reason" => reason,
            "failed_targets" => targets,
            "reviewer_reasons" => rationales,
            "recovery_digest" => digest,
            "published_at" => iso_time(@clock.call)
          )
        end

        def unaccepted_for_identity?(identity, status:)
          pointer = read_current!
          return false unless pointer.fetch("status") == status
          expected_generation = generation_for_identity(identity)
          return false unless pointer.fetch("generation") == expected_generation

          requirement = read_document(
            requirement_path(pointer.fetch("generation")), schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          requirement.fetch("implementation") == canonical_identity(identity) &&
            valid_pointer_digests?(pointer)
        rescue StoreError, SystemCallError
          false
        end

        def build_package(validate_representations:)
          pointer = read_current!
          generation = pointer.fetch("generation")
          requirement_document = requirement(generation: generation)
          unless requirement_document.values_at("task", "project", "generation") ==
                 [ @task.slug.to_s, @project, generation ] && valid_pointer_digests?(pointer)
            raise StoreError, "outcome-evidence current pointer contradicts its generation"
          end
          attempt_documents = attempts(generation: generation)
          named_ids = pointer.fetch("attempts").map { |item| item.fetch("attempt_id") }
          unless attempt_documents.map { |item| item.fetch("attempt_id") } == named_ids
            raise StoreError, "outcome-evidence current pointer omits or reorders attempts"
          end
          if validate_representations
            attempt_documents.each do |attempt|
              validate_retained_evidence!(requirement_document, attempt)
            end
          else
            attempt_documents.each do |attempt|
              validate_retained_metadata!(requirement_document, attempt)
            end
          end
          case pointer.fetch("status")
          when "accepted"
            published_attempt = pointer.fetch("attempts").find do |item|
              item.fetch("attempt_id") == pointer.fetch("attempt_id")
            end
            unless published_attempt &&
                   published_attempt.fetch("attempt_sha256") == pointer.fetch("attempt_sha256")
              raise StoreError, "accepted package attempt digest is inconsistent"
            end
            active_attempt = attempt_documents.find do |attempt|
              attempt.fetch("attempt_id") == pointer.fetch("attempt_id")
            end
            validate_publication!(
              requirement_document, active_attempt, generation,
              pointer.fetch("attempt_id")
            )
          when "blocked", "rework"
            expected = recovery_digest(
              generation: generation, reason: pointer.fetch("reason"),
              attempts: pointer.fetch("attempts"),
              failed_targets: pointer.fetch("failed_targets"),
              reviewer_reasons: pointer.fetch("reviewer_reasons")
            )
            unless pointer.fetch("recovery_digest") == expected &&
                   attempt_documents.none? { |attempt| attempt.fetch("status") == "accepted" }
              raise StoreError, "unaccepted package recovery binding is invalid"
            end
            if pointer.fetch("status") == "blocked" &&
               !BLOCK_REASONS.include?(pointer.fetch("reason"))
              raise StoreError, "blocked package reason is invalid"
            end
            if pointer.fetch("status") == "rework" &&
               (pointer.fetch("reason") != REWORK_REASON ||
                attempt_documents.last&.fetch("status") != "rework")
              raise StoreError, "rework package binding is invalid"
            end
          else
            raise StoreError, "outcome-evidence package status is invalid"
          end
          {
            "current" => pointer,
            "requirement" => requirement_document,
            "attempts" => attempt_documents
          }
        end

        def canonical_reviewer_capabilities(value)
          data = value.to_h.transform_keys(&:to_s)
          unless data.keys.sort == %w[proof_kinds temporal_video]
            raise StoreError, "reviewer capabilities must be a closed object"
          end
          kinds = Array(data.fetch("proof_kinds")).map(&:to_s)
          unless kinds.any? && kinds.uniq == kinds && (kinds - Proof::KINDS).empty?
            raise StoreError, "reviewer proof-kind capabilities are invalid"
          end
          temporal = data.fetch("temporal_video")
          unless [ true, false ].include?(temporal)
            raise StoreError, "reviewer temporal-video capability must be boolean"
          end
          { "proof_kinds" => kinds, "temporal_video" => temporal }
        rescue NoMethodError, KeyError
          raise StoreError, "reviewer capabilities must be a closed object"
        end

        def existing_requirement(generation, canonical:, task_generation:, recovery_epoch:)
          path = requirement_path(generation)
          return nil unless File.exist?(path) || File.symlink?(path)

          existing = read_document(
            path, schema: SCHEMAS.fetch(:requirement),
            label: "outcome-evidence requirement"
          )
          expected = [
            @task.slug.to_s, @project, generation, task_generation,
            recovery_epoch, canonical
          ]
          actual = existing.values_at(
            "task", "project", "generation", "task_generation",
            "recovery_epoch", "implementation"
          )
          unless actual == expected
            raise StoreError, "durable outcome-evidence requirement contradicts controller identity"
          end
          existing
        end

        def publish_pointer!(document)
          source = Document.generate(
            document, schema: SCHEMAS.fetch(:current), label: "outcome-evidence current pointer"
          )
          ensure_store_directories!
          reject_symlink!(current_path, "current pointer")
          Hive::AtomicFile.write(current_path, source, mode: 0o600)
          Hive::AtomicFile.fsync_directory(root)
          read_current!
        end

        def recovery_digest(generation:, reason:, attempts:, failed_targets:,
                            reviewer_reasons:)
          Digest::SHA256.hexdigest(
            [
              "hive-outcome-evidence-recovery-v1", @project, @task.slug.to_s,
              generation, reason,
              attempts.flat_map { |item| item.values_at("attempt_id", "attempt_sha256") },
              failed_targets, reviewer_reasons
            ].flatten.join("\0")
          )
        end

        def valid_pointer_digests?(pointer)
          requirement_file = requirement_path(pointer.fetch("generation"))
          return false unless secure_file_digest(requirement_file) == pointer.fetch("requirement_sha256")

          attempts = pointer.fetch("attempts")
          return false unless attempts.length == pointer.fetch("attempt_count")
          attempts.all? do |item|
            secure_file_digest(
              attempt_path(pointer.fetch("generation"), item.fetch("attempt_id"))
            ) == item.fetch("attempt_sha256")
          end
        end

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

        def candidate_path(generation, attempt_id)
          File.join(generation_root(generation), "retained", attempt_id, "candidate.json")
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

        def ensure_private_directory!(directory, label)
          reject_symlink!(directory, label)
          FileUtils.mkdir_p(directory, mode: 0o700)
          stat = File.lstat(directory)
          unless stat.directory? && !stat.symlink?
            raise StoreError, "#{label} is not a directory"
          end
          FileUtils.chmod(0o700, directory)
        rescue Errno::ELOOP
          raise StoreError, "#{label} must not be a symlink"
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

        def generation_for_identity(identity)
          current_generation(canonical_identity(identity)).fetch(0)
        end

        def current_generation(canonical)
          binding = controller_binding
          task_generation = binding.fetch("task_generation").to_s
          epoch = Integer(binding.fetch("recovery_epoch"))
          raise StoreError, "controller task generation is required" if task_generation.empty?
          raise StoreError, "recovery epoch must be non-negative" if epoch.negative?

          [ generation_for(canonical, task_generation, epoch), task_generation, epoch ]
        end

        def controller_binding
          return @controller_binding.call if @controller_binding

          context = Hive::Attempts::Context.current
          unless context
            raise StoreError,
                  "outcome evidence requires a controller-owned durable attempt context"
          end
          store = @attempt_store || Hive::Attempts::Repository.open_default(create_directories: false)
          record = store.fetch(context.attempt_id)
          unless record && record["project"] == @project &&
                 record["task_slug"] == @task.slug.to_s &&
                 record["intended_stage"] == "7-artifacts" && # coding-scoped: durable ownership for the coding artifacts stage
                 record.ownership_generation == context.ownership_generation
            raise StoreError, "durable attempt does not own this artifacts generation"
          end

          {
            "task_generation" => record.task_input_epoch.to_s,
            "recovery_epoch" => Recovery.new(
              task: @task, project: @project
            ).epoch(task_generation: record.task_input_epoch.to_s)
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

        def write_once_bytes(path, source, generation:)
          if source.bytesize > MAX_DIFF_BYTES
            raise StoreError, "exact implementation diff exceeds #{MAX_DIFF_BYTES} bytes"
          end
          ensure_generation_directories!(generation)
          begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
              file.write(source)
              file.flush
              file.fsync
            end
            Hive::AtomicFile.fsync_directory(File.dirname(path))
          rescue Errno::EEXIST
            existing = begin
              File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
                file.binmode
                file.read
              end
            rescue Errno::ELOOP
              raise StoreError, "exact implementation diff must be a regular file"
            end
            raise StoreError, "exact implementation diff is append-only and already differs" unless existing == source
          end
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

        def validate_retained_evidence!(requirement, attempt)
          canonical_entries = attempt.fetch("evidence").map do |entry|
            canonical = Proof.admit!(
              entry, task_folder: @task.folder,
              expected_head: requirement.dig("implementation", "implementation_head")
            )
            unless canonical == entry
              raise StoreError, "retained outcome evidence is not canonical"
            end
            canonical
          end
          review = attempt.fetch("review")
          canonical_review = Contract.review!(
            requirement: requirement, evidence: canonical_entries,
            producer: attempt.fetch("producer"), reviewer: review.fetch("reviewer"),
            output: review.slice("review_scope_hashes", "verdicts")
          )
          canonical_producer = canonical_review.delete("producer")
          unless canonical_producer == attempt.fetch("producer")
            raise StoreError, "retained outcome-evidence producer is not canonical"
          end
          unless canonical_review == review
            raise StoreError, "retained outcome-evidence review is not canonical"
          end
        end

        def canonical_candidate_evidence!(requirement:, generation:, attempt_id:, evidence:)
          relative_root = Pathname.new(
            File.join(generation_root(generation), "retained", attempt_id)
          ).relative_path_from(Pathname.new(@task.folder)).to_s
          Array(evidence).map do |entry|
            canonical = Proof.admit!(
              entry, task_folder: @task.folder,
              expected_head: requirement.dig("implementation", "implementation_head")
            )
            Array(canonical.fetch("representations")).each do |representation|
              path = representation.fetch("path")
              unless path.start_with?("#{relative_root}/entry-")
                raise StoreError, "outcome-evidence candidate escaped its custody root"
              end
            end
            canonical
          end
        end

        def validate_retained_metadata!(requirement, attempt)
          canonical_entries = attempt.fetch("evidence").map do |entry|
            canonical = Proof.admit_metadata!(
              entry, task_folder: @task.folder,
              expected_head: requirement.dig("implementation", "implementation_head")
            )
            unless canonical == entry
              raise StoreError, "retained outcome evidence metadata is not canonical"
            end
            canonical
          end
          review = attempt.fetch("review")
          canonical_review = Contract.review!(
            requirement: requirement, evidence: canonical_entries,
            producer: attempt.fetch("producer"), reviewer: review.fetch("reviewer"),
            output: review.slice("review_scope_hashes", "verdicts")
          )
          canonical_producer = canonical_review.delete("producer")
          unless canonical_producer == attempt.fetch("producer") && canonical_review == review
            raise StoreError, "retained outcome-evidence review metadata is not canonical"
          end
        end

        def secure_file_digest(path, max_bytes: MAX_DOCUMENT_BYTES)
          File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            raise StoreError, "outcome-evidence document must be regular" unless file.stat.file?

            digest = Digest::SHA256.new
            total = 0
            while (chunk = file.read(16 * 1024))
              total += chunk.bytesize
              raise StoreError, "outcome-evidence document exceeds #{max_bytes} bytes" if total > max_bytes
              digest << chunk
            end
            digest.hexdigest
          end
        rescue Errno::ENOENT, Errno::ELOOP
          nil
        end

        def secure_file_digest!(path, label, max_bytes: MAX_DOCUMENT_BYTES)
          secure_file_digest(path, max_bytes: max_bytes) ||
            raise(StoreError, "#{label} is unavailable")
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

        def validate_claim_id!(value, label)
          claim_id = value.to_s
          raise StoreError, "#{label} is invalid" unless claim_id.match?(Proof::SAFE_CLAIM)

          claim_id
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
