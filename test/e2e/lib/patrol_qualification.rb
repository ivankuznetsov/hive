require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "time"
require "uri"
require "yaml"
require_relative "../../../lib/hive/atomic_file"
require_relative "../../../lib/hive/config"
require_relative "../../../lib/hive/daemon/patrol_fix_semantic_decision_runner"
require_relative "../../../lib/hive/secret_patterns"
require_relative "../../../lib/hive/patrol/launch_budget"
require_relative "../../../lib/hive/patrol_fix/inbox_report"
require_relative "../../../lib/hive/patrol_fix/review_receipt"
require_relative "../../../lib/hive/patrol_fix/source_snapshot"
require_relative "../../../lib/hive/refactor_patrol/merge_classifier"
require_relative "../../../lib/hive/refactor_patrol/merge_classifier_runner"
require_relative "../../../lib/hive/refactor_patrol/review_agent_runner"
require_relative "../../../lib/hive/stages/patrol_fix/inbox"
require_relative "../../../lib/hive/stages/patrol_fix/review"

module Hive
  module E2E
    # Reduced, opt-in U3b successor. It qualifies real persisted shadow records
    # through an exact archived/installed candidate's public CLI. It does not
    # manufacture Patrol state or claim that same-head controls are independent.
    module PatrolQualification
      MODULES = %w[architecture-patrol patrol].freeze
      EXTERNAL_FAULTS = %w[
        cli_failure finalized_outbox_reconciliation_recovery none
        post_reservation_capture_decision_restart provider_failure released_attempt_retry
      ].freeze
      MAX_STREAM_BYTES = 1 * 1024 * 1024
      MAX_STDIN_BYTES = 8 * 1024 * 1024
      MAX_EVIDENCE_BYTES = 512 * 1024
      MAX_SHADOW_FILES = 64
      MAX_SHADOW_BYTES = 8 * 1024 * 1024
      MAX_EXTERNAL_SOURCE_MEMBERS = 4_096
      MAX_EXTERNAL_SOURCE_BYTES = 256 * 1024 * 1024
      MAX_EXTERNAL_SOURCE_PATH_BYTES = 240
      MAX_EXTERNAL_SOURCE_PATH_DEPTH = 32
      MAX_EXTERNAL_GEM_BYTES = 256 * 1024 * 1024
      MAX_EXTERNAL_GEMSPEC_BYTES = 1024 * 1024
      MAX_EXTERNAL_CLOSURE_BYTES = 64 * 1024 * 1024
      MAX_EXTERNAL_HIVE_BYTES = 8 * 1024 * 1024
      CHILD_TIMEOUT = 30.0
      CHILD_TIMEOUT_STATUS = 124
      TERMINAL_SIGNALS = %w[
        HUP INT QUIT ILL TRAP ABRT IOT FPE KILL BUS SEGV SYS PIPE ALRM TERM
        XCPU XFSZ VTALRM PROF USR1 USR2 PWR IO POLL
      ].filter_map { |name| Signal.list[name] }.uniq.freeze
      GIT_OVERRIDES = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false",
        "-c", "credential.helper="
      ].freeze

      class Error < StandardError; end
      class ChildTimeout < Error; end
      class CampaignTimeout < Error; end

      class StreamOverflow < Error
        attr_reader :stream

        def initialize(stream, label)
          @stream = stream
          super("#{label} #{stream} exceeds its byte bound")
        end
      end

      class ProcessFailure < Error
        attr_reader :kind, :status

        def initialize(kind, status, label)
          @kind = kind
          @status = status
          super("#{label} failed (#{kind}=#{status})")
        end
      end

      Result = Data.define(:stdout, :stderr, :status)
      Case = Data.define(:id, :module_name, :decision_class, :fault)
      DecisionCase = Data.define(
        :id, :source, :gate, :safety_critical, :baseline_decision,
        :unsafe_decisions, :prompt_schema_version, :input, :provenance
      )

      module_function

      def canonical(value)
        JSON.generate(canonical_value(value)) + "\n"
      end

      def canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |item| item.to_s == key }
            [ key, canonical_value(value.fetch(original)) ]
          end
        when Array then value.map { |item| canonical_value(item) }
        else value
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def check_deadline!(deadline, label)
        return unless deadline && monotonic >= deadline

        raise CampaignTimeout, "qualification campaign deadline expired while reading #{label}"
      end

      def bounded_read(path, label:, limit: MAX_EVIDENCE_BYTES, deadline: nil)
        check_deadline!(deadline, label)
        raise Error, "#{label} cannot be opened without following links" unless
          File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)

        flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
        File.open(path, flags) do |file|
          stat = file.stat
          raise Error, "#{label} must be a bounded regular file" unless
            stat.file? && stat.size <= limit
          bytes = file.read(limit + 1)
          raise Error, "#{label} exceeds its byte bound" if bytes.bytesize > limit
          check_deadline!(deadline, label)
          bytes
        end
      rescue Errno::ELOOP, Errno::ENXIO, SystemCallError => e
        raise Error, "#{label} is unreadable: #{e.message}"
      end

      class Catalog
        attr_reader :cases, :contracts, :expectations, :bytes

        def self.load(path, deadline: nil)
          new(PatrolQualification.bounded_read(
            path, label: "qualification catalogue", deadline: deadline
          ))
        end

        def initialize(bytes)
          @bytes = bytes.freeze
          data = JSON.parse(bytes)
          exact_keys!(data, %w[cases contracts expectations schema schema_version])
          unless data["schema"] == "hive-patrol-reduced-qualification-catalog" &&
                 data["schema_version"] == 1
            raise Error, "qualification catalogue schema is unsupported"
          end
          @cases = data.fetch("cases").map { |row| parse_case(row) }.freeze
          @contracts = data.fetch("contracts").map { |row| parse_contract(row) }.freeze
          @expectations = parse_expectations(data.fetch("expectations")).freeze
          validate_inventory!
        rescue JSON::ParserError, KeyError, TypeError => e
          raise Error, "qualification catalogue is malformed: #{e.message}"
        end

        private

        def parse_case(row)
          exact_keys!(row, %w[decision_class fault id module proof_kind])
          valid = row["proof_kind"] == "e2e" && safe_id?(row["id"]) &&
            MODULES.include?(row["module"]) && EXTERNAL_FAULTS.include?(row["fault"]) &&
            nonempty?(row["decision_class"])
          raise Error, "qualification E2E case is malformed" unless valid

          Case.new(row["id"], row["module"], row["decision_class"], row["fault"]).freeze
        end

        def parse_contract(row)
          exact_keys!(row, %w[id proof_kind test_file test_method])
          valid = safe_id?(row["id"]) && row["proof_kind"] == "focused_test" &&
            row["test_file"].to_s.start_with?("test/") &&
            row["test_method"].to_s.match?(/\Atest_[a-z0-9_]+\z/)
          raise Error, "qualification focused-test contract is malformed" unless valid
          row.freeze
        end

        def parse_expectations(value)
          exact_keys!(value, MODULES)
          value.to_h do |name, row|
            exact_keys!(row, %w[change_window_count decision_classes decision_count repository_sha_count])
            valid = row.values_at("decision_count", "repository_sha_count", "change_window_count")
                       .all? { |number| number.is_a?(Integer) && number.positive? } &&
              row["decision_classes"].is_a?(Array) &&
              row["decision_classes"].all? { |item| nonempty?(item) }
            raise Error, "qualification expectation is malformed" unless valid
            [ name, row.freeze ]
          end
        end

        def validate_inventory!
          ids = cases.map(&:id) + contracts.map { |row| row.fetch("id") }
          raise Error, "qualification IDs are not unique" unless ids.uniq == ids
          MODULES.each do |name|
            rows = cases.select { |row| row.module_name == name }
            expected = expectations.fetch(name)
            raise Error, "qualification case cardinality differs for #{name}" unless
              rows.size == expected.fetch("decision_count")
            raise Error, "qualification decision classes differ for #{name}" unless
              rows.map(&:decision_class).uniq.sort == expected.fetch("decision_classes").sort
          end
        end

        def exact_keys!(value, keys)
          raise Error, "qualification catalogue keys are malformed" unless
            value.is_a?(Hash) && value.keys.sort == keys.sort
        end

        def safe_id?(value) = value.is_a?(String) && value.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        def nonempty?(value) = value.is_a?(String) && !value.empty?
      end

      # Frozen, human-labeled cases for the four LLM gates in Patrol Fix. This
      # loader is deliberately independent of the legacy U3 qualification
      # catalogue so adding gate labels cannot change its historical counts.
      class DecisionCorpus
        SOURCES = %w[architecture_patrol ordinary_patrol].freeze
        GATES = %w[
          feature_classification inbox_routing independent_review semantic_admission
        ].freeze
        GATE_DECISIONS = {
          "semantic_admission" => %w[same_root distinct insufficient_evidence],
          "feature_classification" => %w[feature skip],
          "inbox_routing" => %w[fix escalate reject blocked],
          "independent_review" => %w[approve rework escalate reject]
        }.freeze
        MAX_CASES = 64
        MAX_BYTES = 256 * 1024
        MAX_INPUT_BYTES = 16 * 1024

        attr_reader :bytes, :cases, :digest

        def self.load(path)
          new(PatrolQualification.bounded_read(
            path, label: "Patrol Fix qualification corpus", limit: MAX_BYTES
          ))
        end

        def initialize(bytes)
          @bytes = bytes.freeze
          document = JSON.parse(bytes)
          exact_keys!(document, %w[cases schema schema_version])
          unless document["schema"] == "hive-patrol-fix-qualification-corpus" &&
                 document["schema_version"] == 1
            raise Error, "Patrol Fix qualification corpus schema is unsupported"
          end
          rows = document.fetch("cases")
          raise Error, "Patrol Fix qualification corpus count is invalid" unless
            rows.is_a?(Array) && rows.size.between?(1, MAX_CASES)
          @cases = rows.map { |row| parse_case(row) }.freeze
          raise Error, "Patrol Fix qualification case IDs are duplicated" unless
            cases.map(&:id).uniq.size == cases.size
          @digest = Digest::SHA256.hexdigest(bytes).freeze
        rescue JSON::ParserError, KeyError, TypeError => e
          raise Error, "Patrol Fix qualification corpus is malformed: #{e.message}"
        end

        private

        def parse_case(row)
          exact_keys!(row, %w[
            baseline_decision gate id input prompt_schema_version safety_critical
            provenance source unsafe_decisions
          ])
          exact_keys!(row.fetch("input"), %w[
            affected_code evidence remediation source_revision summary
          ])
          exact_keys!(row.fetch("provenance"), %w[
            label_rationale origin source_digest source_identity target_revision
          ])
          provenance = row.fetch("provenance")
          valid = safe_id?(row["id"]) && SOURCES.include?(row["source"]) &&
            GATES.include?(row["gate"]) && [ true, false ].include?(row["safety_critical"]) &&
            bounded_text?(row["baseline_decision"], 128) &&
            GATE_DECISIONS.fetch(row["gate"], []).include?(row["baseline_decision"]) &&
            bounded_text?(row["prompt_schema_version"], 128) &&
            string_array?(row["unsafe_decisions"], 16, 128) &&
            row["unsafe_decisions"].all? { |decision| GATE_DECISIONS.fetch(row["gate"], []).include?(decision) } &&
            string_array?(row.dig("input", "affected_code"), 16, 512) &&
            string_array?(row.dig("input", "evidence"), 16, 1024) &&
            bounded_text?(row.dig("input", "remediation"), 4 * 1024) &&
            row.dig("input", "source_revision").to_s.match?(/\A[0-9a-f]{40,64}\z/) &&
            bounded_text?(row.dig("input", "summary"), 4 * 1024) &&
            provenance["origin"] == "historical" &&
            bounded_text?(provenance["source_identity"], 2 * 1024) &&
            provenance["source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
            provenance["target_revision"] == row.dig("input", "source_revision") &&
            bounded_text?(provenance["label_rationale"], 4 * 1024) &&
            PatrolQualification.canonical(row.fetch("input")).bytesize <= MAX_INPUT_BYTES
          raise Error, "Patrol Fix qualification case is malformed" unless valid
          raise Error, "Patrol Fix qualification case contains a secret pattern" if
            Hive::SecretPatterns.scan(PatrolQualification.canonical(row)).any?

          DecisionCase.new(
            row["id"], row["source"], row["gate"], row["safety_critical"],
            row["baseline_decision"], row["unsafe_decisions"].freeze,
            row["prompt_schema_version"], PatrolQualification.canonical_value(row["input"]).freeze,
            PatrolQualification.canonical_value(provenance).freeze
          ).freeze
        end

        def exact_keys!(value, keys)
          raise Error, "Patrol Fix qualification keys are malformed" unless
            value.is_a?(Hash) && value.keys.sort == keys.sort
        end

        def safe_id?(value) = value.is_a?(String) && value.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        def bounded_text?(value, max) = value.is_a?(String) && !value.empty? && value.bytesize <= max
        def string_array?(value, count, max)
          value.is_a?(Array) && value.size <= count && value.all? { |item| bounded_text?(item, max) }
        end
      end

      class DecisionCorpusRunner
        RESULT_KEYS = %w[
          decision evidence model model_receipt production_input_digest
          prompt_version provider rationale
        ].freeze
        MAX_RESULT_BYTES = 32 * 1024

        def initialize(corpus:, gate_runner:)
          @corpus = corpus
          @gate_runner = gate_runner
        end

        def call(generated_at:)
          parse_utc!(generated_at)
          results = @corpus.cases.map { |row| run_case(row) }
          unsafe = results.find { |row| row["status"] == "unsafe_disagreement" }
          raise Error, "unsafe qualification decision for #{unsafe.fetch('case_id')}" if unsafe

          {
            "schema" => "hive-patrol-fix-qualification-report",
            "schema_version" => 1,
            "generated_at" => generated_at,
            "corpus_digest" => @corpus.digest,
            "cases" => results
          }.freeze
        end

        private

        def run_case(row)
          input = {
            "case_id" => row.id,
            "source" => row.source,
            "gate" => row.gate,
            "prompt_schema_version" => row.prompt_schema_version,
            "input_digest" => Digest::SHA256.hexdigest(PatrolQualification.canonical(row.input)),
            "input" => row.input, "provenance" => row.provenance
          }
          result = @gate_runner.call(row, immutable_input: PatrolQualification.canonical_value(input))
          validate_result!(result)
          decision = result.fetch("decision")
          unless DecisionCorpus::GATE_DECISIONS.fetch(row.gate).include?(decision)
            raise Error, "Patrol Fix qualification provider decision is unknown for #{row.gate}"
          end
          status = if decision == row.baseline_decision
            "match"
          elsif row.safety_critical && row.unsafe_decisions.include?(decision)
            "unsafe_disagreement"
          else
            "disagreement"
          end
          PatrolQualification.canonical_value(result).merge(
            "case_id" => row.id,
            "source" => row.source,
            "gate" => row.gate,
            "safety_critical" => row.safety_critical,
            "baseline_decision" => row.baseline_decision,
            "provenance" => row.provenance,
            "input_digest" => input.fetch("input_digest"),
            "status" => status
          ).freeze
        end

        def validate_result!(result)
          valid = result.is_a?(Hash) && result.keys.sort == RESULT_KEYS &&
            RESULT_KEYS.reject { |key| key == "evidence" }.all? do |key|
              result[key].is_a?(String) && !result[key].empty? && result[key].bytesize <= 4 * 1024
            end && result["evidence"].is_a?(Array) && result["evidence"].size.between?(1, 16) &&
            result["evidence"].all? { |item| item.is_a?(String) && !item.empty? && item.bytesize <= 1024 } &&
            PatrolQualification.canonical(result).bytesize <= MAX_RESULT_BYTES
          raise Error, "Patrol Fix qualification provider result is malformed" unless valid
          raise Error, "Patrol Fix qualification provider result contains a secret pattern" if
            Hive::SecretPatterns.scan(PatrolQualification.canonical(result)).any?
        end

        def parse_utc!(value)
          time = Time.iso8601(value.to_s)
          raise Error, "qualification generated_at must be UTC" unless time.utc? && value.end_with?("Z")
        rescue ArgumentError
          raise Error, "qualification generated_at is malformed"
        end
      end

      # Opt-in adapter over the actual four production gate seams. Semantic
      # admission uses its production runner, feature classification uses a
      # production MergeClassifier, and inbox/review reuse the exact production
      # prompt builders and strict output parsers. The injected transport is
      # the only environment-specific part needed to run a configured model.
      class ProductionGateAdapter
        TaskIdentity = Data.define(:slug)
        STRUCTURED_RESULT_KEYS = %w[model model_receipt output provider].freeze

        def initialize(semantic_runner:, feature_classifier:, structured_transport:,
                       provenance:, artifact_root:)
          @semantic_runner = semantic_runner
          @feature_classifier = feature_classifier
          @structured_transport = structured_transport
          @provenance = provenance
          @artifact_root = File.expand_path(artifact_root)
          FileUtils.mkdir_p(@artifact_root)
        end

        def call(row, immutable_input:)
          case row.gate
          when "semantic_admission" then semantic(row, immutable_input)
          when "feature_classification" then feature(row, immutable_input)
          when "inbox_routing" then inbox(row, immutable_input)
          when "independent_review" then review(row, immutable_input)
          else raise Error, "unknown Patrol Fix qualification gate"
          end
        end

        private

        def semantic(row, immutable_input)
          source = source_snapshot(row)
          candidate_evidence = if row.baseline_decision == "distinct"
            {
              "evidence" => [ "The candidate concerns retry scheduling, not the retained architecture root." ],
              "affected_code" => [ "lib/hive/daemon/retry_scheduler.rb" ],
              "remediation" => "Repair retry scheduling without merging unrelated architecture work."
            }
          else
            row.input.slice("evidence", "affected_code", "remediation")
          end
          candidate_core = {
            "kind" => "task", "identity" => "repair-existing",
            "evidence_digest" => "a" * 64, "target_revision" => source.to_h.fetch("target_revision"),
            "manifest_digest" => "b" * 64
          }.merge(candidate_evidence)
          candidate = candidate_core.merge(
            "context_digest" => Digest::SHA256.hexdigest(
              Hive::PatrolFix.canonical_json(candidate_core)
            )
          )
          candidates = [ candidate ]
          inventory_members = candidates.map do |item|
            item.slice(
              "kind", "identity", "evidence_digest", "target_revision",
              "manifest_digest", "context_digest"
            )
          end
          inventory = {
            "count" => candidates.size,
            "digest" => Digest::SHA256.hexdigest(
              Hive::PatrolFix.canonical_json(inventory_members)
            ),
            "context_digest" => Digest::SHA256.hexdigest(
              Hive::PatrolFix.canonical_json(candidates)
            ),
            "truncated" => false
          }
          head = source.to_h.fetch("target_revision")
          input = {
            "schema" => "hive-patrol-fix-semantic-input",
            "schema_version" => 2, "source" => source.to_h,
            "candidate_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
              "current_head" => head, "inventory" => inventory, "candidates" => candidates
            )),
            "current_head" => head, "inventory_count" => inventory.fetch("count"),
            "inventory_digest" => inventory.fetch("digest"),
            "candidate_context_digest" => inventory.fetch("context_digest"),
            "candidate_context_truncated" => false, "candidates" => candidates
          }
          decision = @semantic_runner.call(input)
          result(decision, row, input, immutable_input)
        end

        def feature(row, immutable_input)
          snapshot = feature_snapshot(row)
          record = @feature_classifier.call(snapshot)
          decision = {
            "decision" => record.fetch("decision"),
            "rationale" => record.fetch("rationale"),
            "evidence" => record.fetch("evidence"),
            "model_receipt" => record.fetch("model_receipt")
          }
          result(decision, row, snapshot, immutable_input)
        end

        def inbox(row, immutable_input)
          manifest = task_manifest(row)
          task = TaskIdentity.new("qualification-#{row.id}")
          output_path = structured_output_path(row, "inbox")
          prompt = Hive::Stages::PatrolFix::Inbox.render_prompt(
            task, manifest, row.input.fetch("source_revision"), output_path,
            boundary_token: immutable_input.fetch("input_digest")[0, 16]
          )
          transport = structured("inbox_routing", prompt, output_path: output_path)
          parsed = Hive::PatrolFix::InboxReport.parse(transport.fetch("output"))
          decision = parsed.to_h.slice("rationale", "evidence").merge(
            "decision" => parsed.route, "model_receipt" => transport.fetch("model_receipt")
          )
          result(decision, row, { "prompt" => prompt }, immutable_input,
                 transport: transport)
        end

        def review(row, immutable_input)
          manifest = task_manifest(row)
          task = TaskIdentity.new("qualification-#{row.id}")
          fix = receipt_stub(manifest, "fix", "fix")
          validation = receipt_stub(manifest, "validation", "validate")
          snapshot = {
            "head_revision" => row.input.fetch("source_revision"),
            "diff" => row.input.fetch("summary"), "worktree" => "/qualification/worktree"
          }
          allowed = %w[publish rework escalate reject]
          output_path = structured_output_path(row, "review")
          prompt = Hive::Stages::PatrolFix::Review.render_prompt(
            task, manifest, fix, validation, snapshot, allowed, output_path,
            boundary_token: immutable_input.fetch("input_digest")[0, 16]
          )
          transport = structured("independent_review", prompt, output_path: output_path)
          parsed = Hive::PatrolFix::ReviewReceipt.parse(
            transport.fetch("output"), allowed_routes: allowed
          )
          mapped = parsed.route == "publish" ? "approve" : parsed.route
          decision = {
            "decision" => mapped, "rationale" => parsed.rationale,
            "evidence" => parsed.evidence, "model_receipt" => transport.fetch("model_receipt")
          }
          result(decision, row, { "prompt" => prompt }, immutable_input, transport: transport)
        end

        def result(decision, row, production_input, immutable_input, transport: nil)
          metadata = transport || @provenance.call(row.gate, decision)
          {
            "decision" => decision.fetch("decision"),
            "rationale" => decision.fetch("rationale"),
            "evidence" => decision.fetch("evidence"),
            "model_receipt" => decision.fetch("model_receipt"),
            "provider" => metadata.fetch("provider"), "model" => metadata.fetch("model"),
            "prompt_version" => row.prompt_schema_version,
            "production_input_digest" => Digest::SHA256.hexdigest(PatrolQualification.canonical(
              "production_input" => production_input,
              "immutable_case_input_digest" => immutable_input.fetch("input_digest")
            ))
          }
        end

        def structured(gate, prompt, output_path:)
          value = @structured_transport.call(
            gate: gate, prompt: prompt, output_path: output_path
          )
          unless value.is_a?(Hash) && value.keys.sort == STRUCTURED_RESULT_KEYS &&
                 value.values.all? { |item| item.is_a?(String) && !item.empty? }
            raise Error, "structured qualification transport is malformed"
          end
          value
        end

        def structured_output_path(row, gate)
          unless row.id.match?(/\A[a-z0-9][a-z0-9-]{0,127}\z/)
            raise Error, "qualification case id cannot select an output path"
          end
          File.join(@artifact_root, "#{row.id}-#{gate}.json")
        end

        def source_snapshot(row)
          Hive::PatrolFix::SourceSnapshot.build(
            engine: row.source, identity: row.id, title: row.input.fetch("summary"),
            summary: row.input.fetch("summary"), target_revision: row.input.fetch("source_revision"),
            evidence: row.input.fetch("evidence"), affected_code: row.input.fetch("affected_code"),
            reproduction_guidance: row.input.fetch("remediation"), discovery_run: "qualification-v1",
            semantic_lineage: [ row.id ], aliases: [], external_issues: [],
            existing_pull_requests: [], accepted_at: "2026-08-21T00:00:00Z"
          )
        end

        def feature_snapshot(row)
          revision = row.input.fetch("source_revision")
          Hive::RefactorPatrol::MergeClassifier::SNAPSHOT_KEYS.to_h do |key|
            value = case key
            when "repository" then "example/qualification"
            when "number" then row.id.bytes.sum
            when "url" then "https://github.com/example/qualification/pull/#{row.id.bytes.sum}"
            when "base_branch" then "main"
            when "base_sha", "merge_sha", "target_head" then revision
            when "merged_at" then "2026-08-21T00:00:00Z"
            when "title", "body" then row.input.fetch("summary")
            when "labels" then []
            when "publication_provenance" then { "kind" => "none", "marker" => nil }
            when "author" then "qualification"
            when "changed_paths" then row.input.fetch("affected_code")
            when "files" then row.input.fetch("affected_code").map do |path|
              { "path" => path, "patch" => row.input.fetch("remediation"), "status" => "modified" }
            end
            end
            [ key, value ]
          end
        end

        def task_manifest(row)
          source = source_snapshot(row)
          {
            "schema" => "hive-patrol-fix-task-manifest", "schema_version" => 1,
            "task" => { "slug" => "qualification-#{row.id}", "generation" => 1 },
            "evidence_revision" => { "generation" => 1, "digest" => source.digest },
            "target_revision" => row.input.fetch("source_revision"),
            "sources" => [ source.source_manifest_entry ], "aliases" => [],
            "relations" => { "successor" => nil, "issues" => [] }
          }
        end

        def receipt_stub(manifest, kind, stage)
          {
            "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
            "receipt_id" => "qualification-#{kind}", "kind" => kind, "stage" => stage,
            "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"),
            "recorded_at" => "2026-08-21T00:00:00Z", "payload" => { "qualified" => true }
          }
        end
      end

      # E2E-only executable composition for the opt-in real-provider corpus.
      # It uses the production gate runners and prompt/parser seams but writes
      # all qualification scratch outside project authority.
      class LiveDecisionCorpusController
        class QualificationState
          attr_reader :root

          def initialize(root)
            @root = File.expand_path(root)
          end

          def run_dir(prefix)
            path = File.join(root, "runs", "#{prefix}-#{SecureRandom.hex(8)}")
            FileUtils.mkdir_p(path)
            path
          end
        end

        class StructuredTransport
          def initialize(project_root:, cfg:, state:, launch_budget:)
            @state = state
            @identity = Hive::RefactorPatrol::AgentIdentity.new(
              cfg: cfg, project_root: project_root
            ).review
            @runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
              project_root: project_root, cfg: cfg, state: state,
              dry_run: true, read_only: false, launch_budget: launch_budget
            )
          end

          def call(gate:, prompt:, output_path:)
            FileUtils.rm_f(output_path)
            result = @runner.call(
              prompt: prompt, output_path: output_path,
              run_dir: @state.run_dir("qualification-#{gate}")
            )
            unless result.is_a?(Hash) && result[:status] == :ok
              raise Error, "#{gate} qualification provider failed"
            end
            model = result[:model] || result.dig(:usage, :model) || @identity.model
            {
              "output" => PatrolQualification.bounded_read(
                output_path, label: "#{gate} qualification output", limit: 64 * 1024
              ),
              "provider" => @identity.provider.to_s,
              "model" => model.to_s,
              "model_receipt" => model_receipt(result, model)
            }
          end

          private

          def model_receipt(result, model)
            usage = result[:usage].is_a?(Hash) ? result[:usage] : {}
            digest = Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(
              "model" => model.to_s, "session" => result[:session_id].to_s,
              "usage" => usage.transform_keys(&:to_s).sort.to_h
            ))
            "provider:#{model}:#{digest[0, 32]}"
          end
        end

        def initialize(project_root:, corpus_path:, evidence_path:, adapter_factory: nil)
          @project_root = File.expand_path(project_root)
          @corpus_path = File.expand_path(corpus_path)
          @evidence_path = File.expand_path(evidence_path)
          @adapter_factory = adapter_factory
        end

        def run!(generated_at: Time.now.utc.iso8601(6))
          corpus = DecisionCorpus.load(@corpus_path)
          Dir.mktmpdir("patrol-fix-live-qualification") do |scratch|
            adapter = @adapter_factory ?
              @adapter_factory.call(corpus: corpus, artifact_root: scratch) :
              production_adapter(scratch)
            report = DecisionCorpusRunner.new(corpus: corpus, gate_runner: adapter).call(
              generated_at: generated_at
            )
            Hive::AtomicFile.write(
              @evidence_path, PatrolQualification.canonical(report), mode: 0o600
            )
            report
          end
        end

        private

        def production_adapter(scratch)
          cfg = Hive::Config.load(@project_root)
          state = QualificationState.new(scratch)
          budget = Hive::Patrol::LaunchBudget.new(
            @project_root, cfg: cfg, charge_discovery: false
          )
          identity = Hive::RefactorPatrol::AgentIdentity.new(
            cfg: cfg, project_root: @project_root
          ).review
          ProductionGateAdapter.new(
            semantic_runner: Hive::Daemon::PatrolFixSemanticDecisionRunner.new(
              project_root: @project_root, cfg: cfg, state: state, launch_budget: budget
            ),
            feature_classifier: Hive::RefactorPatrol::MergeClassifier.new(
              root: File.join(scratch, "merge-classifications"),
              decision_provider: Hive::RefactorPatrol::MergeClassifierRunner.new(
                project_root: @project_root, cfg: cfg, state: state, launch_budget: budget
              )
            ),
            structured_transport: StructuredTransport.new(
              project_root: @project_root, cfg: cfg, state: state, launch_budget: budget
            ),
            provenance: lambda do |_gate, _decision|
              { "provider" => identity.provider.to_s, "model" => identity.model.to_s }
            end,
            artifact_root: File.join(scratch, "structured")
          )
        end
      end

      # Minimal durable evidence shape for a later opt-in live dogfood run. It
      # records observations only; the writer does not execute any workflow or
      # remote operation.
      class DogfoodReport
        STAGES = %w[inbox fix validate review publish done].freeze
        MAX_BYTES = 256 * 1024

        class << self
          def load(path)
            document = JSON.parse(PatrolQualification.bounded_read(
              path, label: "Patrol Fix dogfood report", limit: MAX_BYTES
            ))
            validate!(document)
          rescue JSON::ParserError => e
            raise Error, "Patrol Fix dogfood report is malformed: #{e.message}"
          end

          def write(path, document)
            value = validate!(document)
            bytes = PatrolQualification.canonical(value)
            raise Error, "Patrol Fix dogfood report exceeds its byte bound" if bytes.bytesize > MAX_BYTES
            raise Error, "Patrol Fix dogfood report contains a secret pattern" if
              Hive::SecretPatterns.scan(bytes).any?
            Hive::AtomicFile.write(path, bytes, mode: 0o600)
            value
          end

          def validate!(document)
            exact!(document, %w[
              generated_at project publication replay review run_id schema schema_version
              source stages task validation
            ])
            valid = document["schema"] == "hive-patrol-fix-dogfood-report" &&
              document["schema_version"] == 1 && text?(document["run_id"], 256) &&
              text?(document["project"], 256) && utc?(document["generated_at"])
            raise Error, "Patrol Fix dogfood report envelope is malformed" unless valid
            validate_source!(document.fetch("source"))
            validate_task!(document.fetch("task"))
            validate_stages!(document.fetch("stages"))
            validate_validation!(document.fetch("validation"))
            validate_review!(document.fetch("review"))
            validate_publication!(document.fetch("publication"))
            validate_replay!(document.fetch("replay"), document)
            PatrolQualification.canonical_value(document)
          rescue KeyError, TypeError => e
            raise Error, "Patrol Fix dogfood report is malformed: #{e.message}"
          end

          private

          def validate_source!(value)
            exact!(value, %w[engine identity occurrence_id source_digest])
            raise Error, "Patrol Fix dogfood source is malformed" unless
              %w[architecture_patrol ordinary_patrol].include?(value["engine"]) &&
              %w[identity occurrence_id].all? { |key| text?(value[key], 512) } && digest?(value["source_digest"])
          end

          def validate_task!(value)
            exact!(value, %w[evidence_digest generation slug])
            raise Error, "Patrol Fix dogfood task is malformed" unless
              text?(value["slug"], 256) && value["generation"].is_a?(Integer) &&
              value["generation"].positive? && digest?(value["evidence_digest"])
          end

          def validate_stages!(value)
            valid = value.is_a?(Array) && value.size == STAGES.size &&
              value.map { |row| row["stage"] } == STAGES && value.all? do |row|
                exact!(row, %w[journal_digest observed_at stage status])
                text?(row["status"], 64) && digest?(row["journal_digest"]) && utc?(row["observed_at"])
              end
            raise Error, "Patrol Fix dogfood stages are malformed" unless valid
          end

          def validate_validation!(value)
            valid = value.is_a?(Array) && value.size.between?(1, 32) && value.all? do |row|
              exact!(row, %w[command evidence_digest exit_code])
              text?(row["command"], 4 * 1024) && row["exit_code"].is_a?(Integer) &&
                digest?(row["evidence_digest"])
            end
            raise Error, "Patrol Fix dogfood validation is malformed" unless valid
          end

          def validate_review!(value)
            exact!(value, %w[decision evidence_digest model_receipt])
            raise Error, "Patrol Fix dogfood review is malformed" unless
              %w[approve rework escalate reject].include?(value["decision"]) &&
              text?(value["model_receipt"], 4 * 1024) && digest?(value["evidence_digest"])
          end

          def validate_publication!(value)
            exact!(value, %w[base_revision head_revision phase pr_number receipt_digest url])
            raise Error, "Patrol Fix dogfood publication is malformed" unless
              value["phase"] == "pr_created" && value["pr_number"].is_a?(Integer) &&
              value["pr_number"].positive? && text?(value["url"], 2 * 1024) &&
              URI::DEFAULT_PARSER.make_regexp(%w[https]).match?(value["url"]) &&
              revision?(value["base_revision"]) && revision?(value["head_revision"]) &&
              digest?(value["receipt_digest"])
          end

          def validate_replay!(value, document)
            exact!(value, %w[duplicate_pr_count duplicate_task_count pr_number source_occurrence_id task_slug])
            valid = text?(value["source_occurrence_id"], 512) && text?(value["task_slug"], 256) &&
              value["duplicate_pr_count"] == 0 && value["duplicate_task_count"] == 0 &&
              value["source_occurrence_id"] == document.dig("source", "occurrence_id") &&
              value["task_slug"] == document.dig("task", "slug") &&
              value["pr_number"] == document.dig("publication", "pr_number")
            raise Error, "Patrol Fix dogfood replay proof is malformed" unless valid
          end

          def exact!(value, keys)
            raise Error, "Patrol Fix dogfood report keys are malformed" unless
              value.is_a?(Hash) && value.keys.sort == keys.sort
            true
          end

          def digest?(value) = value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
          def revision?(value) = value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
          def text?(value, max) = value.is_a?(String) && !value.empty? && value.bytesize <= max
          def utc?(value)
            time = Time.iso8601(value.to_s)
            time.utc? && value.end_with?("Z")
          rescue ArgumentError
            false
          end
        end
      end

      class ChildProcess
        def initialize(deadline:, env:)
          @deadline = deadline
          @env = env.freeze
        end

        def run(*command, label:, cwd:, stdin_data: "", timeout: CHILD_TIMEOUT)
          raise Error, "#{label} stdin exceeds its bound" if stdin_data.bytesize > MAX_STDIN_BYTES
          remaining = @deadline - monotonic
          raise CampaignTimeout, "qualification campaign deadline expired" unless remaining.positive?
          campaign_limited = remaining <= timeout
          limit = [ remaining, timeout ].min
          command_deadline = monotonic + limit
          stdout = +""
          stderr = +""
          status = nil
          pid = nil
          cleaned_up = false
          streams = []
          workers = []
          Open3.popen3(@env, *command, chdir: cwd, pgroup: true, unsetenv_others: true) do |input, out, err, wait|
            pid = wait.pid
            input.binmode
            streams = [ input, out, err ]
            workers = [
              Thread.new { drain(out, stdout, stream: "stdout", label:, pid:) },
              Thread.new { drain(err, stderr, stream: "stderr", label:, pid:) }
            ]
            workers << Thread.new do
              input.write(stdin_data)
            rescue Errno::EPIPE, IOError
              nil
            ensure
              close(input)
            end
            workers.each { |thread| thread.report_on_exception = false }
            unless wait.join(limit)
              terminate_group(pid)
              streams.each { |io| close(io) }
              join_until(workers, monotonic + 0.5)
              raise_worker_errors!(workers)
              cleaned_up = true
              raise(campaign_limited ? CampaignTimeout : ChildTimeout,
                    "#{label} exceeded #{limit.round(3)} seconds")
            end
            status = wait.value
            terminate_group(pid)
            cleaned_up = true
            unless join_until(workers, command_deadline)
              terminate_group(pid)
              streams.each { |io| close(io) }
              join_until(workers, monotonic + 0.5)
              raise(campaign_limited ? CampaignTimeout : ChildTimeout,
                    "#{label} did not close its process streams before the deadline")
            end
            raise_worker_errors!(workers)
          end
          unless status.success?
            kind, value = status.signaled? ? [ "signal", status.termsig ] : [ "exit", status.exitstatus ]
            raise ProcessFailure.new(kind, value, label)
          end
          Result.new(stdout.freeze, stderr.freeze, status.exitstatus).freeze
        rescue SystemCallError => e
          raise ProcessFailure.new("spawn", e.class.name, label)
        ensure
          if pid && !cleaned_up
            terminate_group(pid)
            streams.each { |io| close(io) }
            join_until(workers, monotonic + 0.5)
          end
        end

        private

        def drain(io, destination, stream:, label:, pid:)
          while (chunk = io.read(16 * 1024))
            remaining = MAX_STREAM_BYTES - destination.bytesize
            if chunk.bytesize > remaining
              begin
                Process.kill("TERM", -pid)
              rescue Errno::ESRCH
                nil
              end
              raise StreamOverflow.new(stream, label)
            end
            destination << chunk
          end
        rescue IOError
          nil
        ensure
          close(io)
        end

        def terminate_group(pid)
          Process.kill("TERM", -pid)
          deadline = monotonic + 0.5
          sleep 0.02 while monotonic < deadline && process_group_alive?(pid)
          Process.kill("KILL", -pid) if process_group_alive?(pid)
          Process.waitpid(pid) rescue nil
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def process_group_alive?(pid)
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH
          false
        end

        def join_until(threads, deadline)
          threads.each do |thread|
            remaining = deadline - monotonic
            break unless remaining.positive?
            thread.join(remaining)
          end
          threads.none?(&:alive?)
        end

        def raise_worker_errors!(threads)
          threads.each { |thread| thread.value unless thread.alive? }
        end

        def close(io)
          io.close unless io.closed?
        rescue IOError, SystemCallError
          nil
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      class ObservationReader
        attr_reader :bytes

        OBSERVATION_KEYS = %w[
          change_window fault_observed id process_outcomes repository_sha trigger_id
        ].freeze
        OUTCOME_KEYS = %w[kind status].freeze
        OUTCOME_KINDS = %w[child_timeout exit signal].freeze

        def initialize(project_root:, observations_path:, catalog:, deadline: nil)
          @project_root = File.expand_path(project_root)
          @catalog = catalog
          @deadline = deadline
          @observations = read_observations(observations_path)
        end

        def each
          records = comparable_records
          selected = []
          @catalog.cases.each do |case_row|
            observation = @observations.fetch(case_row.id)
            unless observation.fetch("fault_observed") == case_row.fault
              raise Error, "#{case_row.id} fault observation differs from the catalogue"
            end
            matches = records.select do |record|
              record.fetch("module") == case_row.module_name &&
                record.dig("trigger", "id") == observation.fetch("trigger_id")
            end
            raise Error, "#{case_row.id} does not select exactly one shadow record" unless matches.one?
            record = matches.first
            unless record.dig("module_decision", "rationale") == case_row.decision_class
              raise Error, "#{case_row.id} decision class differs from the catalogue"
            end
            selected << [ record.fetch("module"), record.dig("trigger", "id") ]
            yield case_row, observation, record
          end
          unless selected.uniq.size == records.size
            raise Error, "qualification selectors do not cover each shadow record exactly once"
          end
          validate_cardinality!(records)
        end

        private

        def read_observations(path)
          @bytes = PatrolQualification.bounded_read(
            path, label: "qualification observations", deadline: @deadline
          ).freeze
          data = JSON.parse(@bytes)
          unless data.is_a?(Hash) && data.keys.sort == %w[cases schema schema_version] &&
                 data["schema"] == "hive-patrol-reduced-observations" && data["schema_version"] == 1
            raise Error, "qualification observations are malformed"
          end
          rows = data.fetch("cases")
          raise Error, "qualification observation cardinality is malformed" unless rows.is_a?(Array)
          ids = rows.map { |row| row.is_a?(Hash) ? row["id"] : nil }
          unless ids.none?(&:nil?) && ids.uniq.size == ids.size
            raise Error, "qualification observation IDs are duplicated"
          end
          unless rows.size == @catalog.cases.size
            raise Error, "qualification observation cardinality is malformed"
          end
          result = rows.to_h do |row|
            raise Error, "qualification observation keys are malformed" unless
              row.is_a?(Hash) && row.keys.sort == OBSERVATION_KEYS
            valid = row["repository_sha"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
              EXTERNAL_FAULTS.include?(row["fault_observed"]) &&
              [ row["id"], row["trigger_id"], row["change_window"] ].all? { |item| item.is_a?(String) && !item.empty? }
            valid &&= valid_process_outcomes?(row)
            raise Error, "qualification observation is malformed" unless valid
            [ row.fetch("id"), row.freeze ]
          end
          raise Error, "qualification observation IDs differ from the catalogue" unless
            result.keys.sort == @catalog.cases.map(&:id).sort
          result.freeze
        rescue JSON::ParserError, KeyError => e
          raise Error, "qualification observations are malformed: #{e.message}"
        end

        def valid_process_outcomes?(row)
          outcomes = row["process_outcomes"]
          return false unless outcomes.is_a?(Array) && !outcomes.empty? && outcomes.size <= 4
          return false unless outcomes.all? do |outcome|
            next false unless outcome.is_a?(Hash) && outcome.keys.sort == OUTCOME_KEYS &&
                              OUTCOME_KINDS.include?(outcome["kind"])

            case outcome["kind"]
            when "exit"
              outcome["status"].is_a?(Integer) && outcome["status"].between?(0, 255)
            when "signal"
              outcome["status"].is_a?(Integer) && TERMINAL_SIGNALS.include?(outcome["status"])
            when "child_timeout"
              outcome["status"] == CHILD_TIMEOUT_STATUS
            end
          end

          failed = ->(outcome) { outcome["kind"] != "exit" || outcome["status"] != 0 }
          successful = ->(outcome) { outcome == { "kind" => "exit", "status" => 0 } }
          case row.fetch("fault_observed")
          when "none" then outcomes.one? && successful.call(outcomes.first)
          when "provider_failure", "cli_failure" then outcomes.any? { |item| failed.call(item) }
          when "post_reservation_capture_decision_restart"
            outcomes.first["kind"] == "signal" && outcomes.any? { |item| successful.call(item) }
          when "released_attempt_retry"
            outcomes.size >= 2 && failed.call(outcomes.first) && successful.call(outcomes.last)
          when "finalized_outbox_reconciliation_recovery"
            outcomes.size >= 2 && outcomes.first["kind"] == "signal" && successful.call(outcomes.last)
          else false
          end
        end

        def comparable_records
          root = File.join(state_path, "module-runtime", "migration", "shadow")
          records = []
          extra = false
          file_count = 0
          byte_count = 0
          MODULES.each do |name|
            directory = File.join(root, name)
            directory_stat = File.lstat(directory)
            raise Error, "shadow evidence directory must not be linked" unless
              directory_stat.directory? && !directory_stat.symlink?
            paths = []
            Dir.foreach(directory) do |entry|
              next if entry == "." || entry == ".."

              PatrolQualification.check_deadline!(@deadline, "shadow inventory")
              file_count += 1
              raise Error, "shadow evidence exceeds its file-count bound" if file_count > MAX_SHADOW_FILES
              raise Error, "shadow evidence contains an unexpected child" unless entry.match?(/\A[0-9a-f]{64}\.json\z/)
              paths << File.join(directory, entry)
            end
            paths.sort.each do |path|
              bytes = PatrolQualification.bounded_read(
                path, label: "shadow evidence", deadline: @deadline
              )
              byte_count += bytes.bytesize
              raise Error, "shadow evidence exceeds its aggregate byte bound" if byte_count > MAX_SHADOW_BYTES
              record = JSON.parse(bytes)
              unless bytes == PatrolQualification.canonical(record)
                raise Error, "shadow evidence is not canonical JSON"
              end
              next unless record["comparable"] == true && record["legacy_capture"]

              if records.size < @catalog.cases.size
                records << record
              else
                extra = true
              end
            end
          end
          raise Error, "shadow evidence contains extra or missing comparable records" unless
            !extra && records.size == @catalog.cases.size
          records
        rescue JSON::ParserError, SystemCallError, TypeError => e
          raise Error, "shadow evidence is unreadable: #{e.message}"
        end

        def validate_cardinality!(records)
          MODULES.each do |name|
            rows = records.select { |record| record.fetch("module") == name }
            observations = @catalog.cases.select { |item| item.module_name == name }
                                        .map { |item| @observations.fetch(item.id) }
            expected = @catalog.expectations.fetch(name)
            actual = {
              "decision_count" => rows.size,
              "repository_sha_count" => observations.map { |row| row.fetch("repository_sha") }.uniq.size,
              "change_window_count" => observations.map { |row| row.fetch("change_window") }.uniq.size
            }
            actual.each do |key, value|
              raise Error, "#{name} #{key} differs from the catalogue" unless value == expected.fetch(key)
            end
            classes = rows.map { |record| record.dig("module_decision", "rationale") }.uniq.sort
            raise Error, "#{name} decision classes differ from the catalogue" unless
              classes == expected.fetch("decision_classes").sort
            configurations = rows.map { |record| record["configuration_digest"] }.uniq
            raise Error, "#{name} configuration is missing or changed" unless
              configurations.one? && configurations.first.to_s.match?(/\A[0-9a-f]{64}\z/)
          end
        end

        def state_path
          config = YAML.safe_load(PatrolQualification.bounded_read(
            File.join(@project_root, ".hive-state", "config.yml"),
            label: "qualification project config", deadline: @deadline
          )) || {}
          File.expand_path(config.fetch("hive_state_path", ".hive-state"), @project_root)
        rescue Psych::Exception, SystemCallError
          File.join(@project_root, ".hive-state")
        end
      end

      class Controller
        def initialize(repo_root:, project_root:, hive_home:, observations_path:, evidence_root:,
                       campaign_timeout: 300.0, child_timeout: CHILD_TIMEOUT)
          @repo_root = File.expand_path(repo_root)
          @project_root = File.expand_path(project_root)
          @hive_home = File.expand_path(hive_home)
          @observations_path = File.expand_path(observations_path)
          @evidence_root = File.expand_path(evidence_root)
          @deadline = monotonic + campaign_timeout
          @child_timeout = child_timeout
        end

        def run!
          Dir.mktmpdir("hive-patrol-u3br") do |run_root|
            setup_process(run_root)
            candidate = materialize_candidate(run_root)
            catalog = Catalog.load(
              File.join(candidate.fetch("root"), "test/e2e/fixtures/patrol_qualification/catalog.json"),
              deadline: @deadline
            )
            install_candidate(candidate, run_root)
            catalog_repo = build_module_catalog(candidate, run_root)
            install_modules(catalog_repo)
            prepared = collect_receipts(catalog, candidate)
            report = admit_qualification(prepared)
            proof = proof(candidate, catalog, report, prepared)
            write_evidence(proof)
            proof
          rescue StandardError => e
            write_evidence("status" => "failed", "error_class" => e.class.name,
                           "error" => e.message.to_s.byteslice(0, 2048))
            raise
          end
        end

        # Read-only U3c seam. The worker branch runs only the archived candidate's
        # build/install/receipt commands inside the admitted sandbox; this host
        # branch independently replays the trusted catalogue controls and never
        # reaches qualification/report publication.
        def external_smoke(controller_sha:, candidate_sha:, candidate:, sandbox_result: nil,
                           trusted_catalog_path: nil, worker: false)
          return external_smoke_worker(
            controller_sha:, candidate_sha:, candidate:, trusted_catalog_path:
          ) if worker

          unless controller_sha.to_s.match?(/\A[0-9a-f]{40}\z/) &&
                 candidate_sha.to_s.match?(/\A[0-9a-f]{40}\z/) &&
                 controller_sha != candidate_sha && candidate.is_a?(Hash) &&
                 candidate.fetch("candidate_sha") == candidate_sha &&
                 candidate.fetch("archive_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 candidate.fetch("module_manifest_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 candidate.fetch("source_tree_sha256").to_s.match?(/\A[0-9a-f]{64}\z/)
            raise Error, "external smoke authority binding is malformed"
          end
          unless sandbox_result.is_a?(Hash) && sandbox_result.keys.sort == %w[
            generated_at module_inspections receipts report_after_sha256 report_before_sha256
          ]
            raise Error, "external smoke sandbox result is malformed"
          end
          generated_at = Time.iso8601(sandbox_result.fetch("generated_at"))
          raise Error, "external smoke generation time must be UTC" unless generated_at.utc_offset.zero?

          catalog = Catalog.load(
            File.join(@repo_root, "test/e2e/fixtures/patrol_qualification/catalog.json"),
            deadline: @deadline
          )
          reader = ObservationReader.new(
            project_root: @project_root, observations_path: @observations_path,
            catalog:, deadline: @deadline
          )
          catalog_digest = Digest::SHA256.hexdigest(catalog.bytes)
          common = {
            "run_id" => "u3c-#{candidate_sha[0, 12]}",
            "candidate_sha" => candidate_sha,
            "catalog_digest" => catalog_digest,
            "source_digest" => candidate.fetch("archive_sha256"),
            "manifest_digest" => candidate.fetch("module_manifest_sha256"),
            "scenario_manifest_digest" => Digest::SHA256.hexdigest(catalog.bytes + "\0" + reader.bytes),
            "artifacts" => [
              { "kind" => "candidate_archive", "digest" => candidate.fetch("archive_sha256") },
              { "kind" => "scenario_catalog", "digest" => catalog_digest }
            ],
            "reviewer" => "hive-e2e/u3c-smoke"
          }
          expected_receipts = []
          configurations = Hash.new { |hash, key| hash[key] = [] }
          reader.each do |case_row, observation, record|
            expected_receipts << expected_receipt(
              common, case_row, observation, record, sandbox_result.fetch("generated_at")
            )
            configurations[case_row.module_name] << record.fetch("configuration_digest")
          end
          unless PatrolQualification.canonical(sandbox_result.fetch("receipts")) ==
                 PatrolQualification.canonical(expected_receipts)
            raise Error, "external smoke receipts differ from the trusted controls"
          end
          inspections = sandbox_result.fetch("module_inspections")
          unless inspections.is_a?(Hash) && inspections.keys.sort == MODULES.sort
            raise Error, "external smoke module inspection inventory differs"
          end
          MODULES.each do |name|
            expected_configuration = configurations.fetch(name).uniq
            row = inspections.fetch(name)
            valid = expected_configuration.one? && row.is_a?(Hash) &&
              row.keys.sort == %w[configuration_digest status] &&
              row.values_at("status", "configuration_digest") ==
                [ "active", expected_configuration.fetch(0) ]
            raise Error, "external smoke #{name} revalidation differs" unless valid
          end
          report_digest = Digest::SHA256.hexdigest(read_report(
            File.join(state_path, "module-runtime", "migration", "report.json")
          ))
          before, after = sandbox_result.values_at("report_before_sha256", "report_after_sha256")
          unless before.to_s.match?(/\A[0-9a-f]{64}\z/) && before == after && before == report_digest
            raise Error, "external smoke changed the migration report"
          end
          {
            "status" => "passed", "modules" => MODULES,
            "receipt_count" => expected_receipts.size,
            "catalog_digest" => catalog_digest,
            "scenario_manifest_digest" => common.fetch("scenario_manifest_digest"),
            "report_sha256" => report_digest
          }.freeze
        rescue ArgumentError, KeyError, TypeError => e
          raise Error, "external smoke result is malformed: #{e.class.name}"
        end

        private

        def external_smoke_worker(controller_sha:, candidate_sha:, candidate:, trusted_catalog_path:)
          unless controller_sha.to_s.match?(/\A[0-9a-f]{40}\z/) &&
                 candidate_sha.to_s.match?(/\A[0-9a-f]{40}\z/) &&
                 controller_sha != candidate_sha && candidate.is_a?(Hash) &&
                 candidate.fetch("candidate_sha") == candidate_sha &&
                 candidate.fetch("archive_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 candidate.fetch("module_manifest_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 candidate.fetch("source_tree_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
                 candidate.fetch("source_root").is_a?(String) &&
                 File.absolute_path(candidate.fetch("source_root")) == candidate.fetch("source_root")
            raise Error, "external smoke worker authority binding is malformed"
          end
          run_root = File.join(File.dirname(@repo_root), "external-smoke")
          raise Error, "external smoke worker root must not pre-exist" if File.exist?(run_root)
          Dir.mkdir(run_root, 0o700)
          FileUtils.mkdir_p(@evidence_root, mode: 0o700)
          setup_process(run_root)
          catalog = Catalog.load(trusted_catalog_path, deadline: @deadline)
          report_path = File.join(state_path, "module-runtime", "migration", "report.json")
          report_before = read_report(report_path)
          installed = {
            "sha" => candidate_sha, "candidate_sha" => candidate_sha,
            "archive_sha256" => candidate.fetch("archive_sha256"), "root" => @repo_root,
            "source_root" => candidate.fetch("source_root"),
            "source_tree_sha256" => candidate.fetch("source_tree_sha256"),
            "module_manifest_sha256" => candidate.fetch("module_manifest_sha256")
          }
          install_candidate(installed, run_root)
          catalog_repo = build_module_catalog(installed, run_root)
          install_modules(catalog_repo)
          identity_before = external_installed_identity(installed)
          unless identity_before.values_at("source_tree_sha256", "module_manifest_sha256") ==
                 installed.values_at("source_tree_sha256", "module_manifest_sha256")
            raise Error, "external smoke admitted source identity differs"
          end
          prepared = collect_receipts(catalog, installed, claim: "u3c")
          inspections = revalidate_external_modules
          identity_after = external_installed_identity(installed)
          report_after = read_report(report_path)
          unless report_before == report_after
            raise Error, "external smoke worker changed the migration report"
          end
          {
            "candidate" => {
              "candidate_sha" => candidate_sha,
              "archive_sha256" => candidate.fetch("archive_sha256"),
              "identity_before" => identity_before,
              "identity_after" => identity_after
            },
            "payload" => {
              "generated_at" => prepared.fetch("generated_at"),
              "receipts" => prepared.fetch("receipts"),
              "module_inspections" => inspections,
              "report_before_sha256" => Digest::SHA256.hexdigest(report_before),
              "report_after_sha256" => Digest::SHA256.hexdigest(report_after)
            }
          }
        rescue SystemCallError, JSON::ParserError, Psych::Exception => e
          raise Error, "external smoke worker failed: #{e.class.name}"
        end

        def revalidate_external_modules
          MODULES.to_h do |name|
            expected = @installed_generations.fetch(name)
            inspected = JSON.parse(hive([ "module", "inspect", name, "--json" ]).stdout)
            validate_inspection!(inspected, name:, expected:)
            [ name, {
              "status" => "active",
              "configuration_digest" => expected.fetch("configuration_digest")
            } ]
          end
        end

        def external_installed_identity(candidate)
          specifications = File.join(@install_root, "specifications")
          stat = File.lstat(specifications)
          unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
            raise Error, "installed dependency specifications are unavailable"
          end
          closure = []
          closure_bytes = 0
          Dir.each_child(specifications) do |name|
            raise Error, "installed dependency closure exceeds its member bound" if closure.size >= 4_096
            unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,239}\.gemspec\z/)
              raise Error, "installed dependency specification name is unsafe"
            end
            path = File.join(specifications, name)
            identity = external_regular_file_identity(
              path, label: "installed dependency specification",
              limit: MAX_EXTERNAL_GEMSPEC_BYTES
            )
            closure_bytes += identity.fetch("bytesize")
            raise Error, "installed dependency closure exceeds its aggregate byte bound" if
              closure_bytes > MAX_EXTERNAL_CLOSURE_BYTES
            closure << {
              "basename" => name, "bytesize" => identity.fetch("bytesize"),
              "spec_sha256" => identity.fetch("sha256")
            }
          end
          closure.sort_by! { |row| row.fetch("basename") }
          names = closure.map { |row| row.fetch("basename") }
          raise Error, "installed dependency closure is empty or duplicated" if
            closure.empty? || names.uniq.size != names.size
          toolchain = {
            "ruby" => run("ruby", "--version", label: "resolve installed Ruby").stdout.strip,
            "rubygems" => run("gem", "--version", label: "resolve installed RubyGems").stdout.strip,
            "bundler" => run("bundle", "--version", label: "resolve installed Bundler").stdout.strip
          }
          canonical_closure = JSON.generate(PatrolQualification.canonical_value(closure))
          canonical_toolchain = JSON.generate(PatrolQualification.canonical_value(toolchain))
          source_tree_sha256 = external_source_tree_sha256(candidate.fetch("source_root"))
          module_manifest_sha256 = external_module_manifest_sha256(candidate.fetch("source_root"))
          {
            "gem_sha256" => external_regular_file_identity(
              @candidate_gem_path, label: "built candidate gem", limit: MAX_EXTERNAL_GEM_BYTES
            ).fetch("sha256"),
            "installed_hive_sha256" => external_regular_file_identity(
              @hive_bin, label: "installed candidate hive", limit: MAX_EXTERNAL_HIVE_BYTES
            ).fetch("sha256"),
            "module_manifest_sha256" => module_manifest_sha256,
            "source_tree_sha256" => source_tree_sha256,
            "dependency_closure" => closure,
            "dependency_closure_sha256" => Digest::SHA256.hexdigest(canonical_closure),
            "toolchain" => toolchain,
            "toolchain_sha256" => Digest::SHA256.hexdigest(canonical_toolchain)
          }
        rescue Errno::ENOENT, Errno::EACCES
          raise Error, "installed dependency closure is unavailable"
        end

        def external_regular_file_identity(path, label:, limit:)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
          File.open(path, flags) do |file|
            stat = file.stat
            unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid &&
                   stat.size.between?(1, limit)
              raise Error, "#{label} is not a bounded owner-controlled regular file"
            end
            digest = Digest::SHA256.new
            bytesize = 0
            while (chunk = file.read(64 * 1024))
              bytesize += chunk.bytesize
              raise Error, "#{label} exceeds its byte bound" if bytesize > limit
              digest.update(chunk)
              PatrolQualification.check_deadline!(@deadline, label)
            end
            { "bytesize" => bytesize, "sha256" => digest.hexdigest }
          end
        rescue Errno::ELOOP, Errno::ENXIO, SystemCallError => e
          raise Error, "#{label} is unreadable: #{e.class.name}"
        end

        def external_regular_file_bytes(path, label:, limit:)
          identity = external_regular_file_identity(path, label:, limit:)
          bytes = PatrolQualification.bounded_read(path, label:, limit:, deadline: @deadline)
          unless bytes.bytesize == identity.fetch("bytesize") &&
                 Digest::SHA256.hexdigest(bytes) == identity.fetch("sha256")
            raise Error, "#{label} changed while it was read"
          end
          bytes
        end

        def external_module_manifest_sha256(source_root)
          manifests = MODULES.to_h do |name|
            bytes = external_regular_file_bytes(
              File.join(source_root, "modules", name, "manifest.yml"),
              label: "admitted #{name} module manifest", limit: 1024 * 1024
            )
            manifest = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
            valid = manifest.is_a?(Hash) && manifest["version"].is_a?(String) &&
              manifest["release_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
              manifest.dig("source", "revision").to_s.match?(/\A[0-9a-f]{40}\z/)
            raise Error, "admitted #{name} module manifest is malformed" unless valid
            [ name, {
              "bytes_sha256" => Digest::SHA256.hexdigest(bytes),
              "version" => manifest.fetch("version"),
              "release_sha256" => manifest.fetch("release_sha256"),
              "source_revision" => manifest.dig("source", "revision")
            } ]
          end
          Digest::SHA256.hexdigest(JSON.generate(PatrolQualification.canonical_value(manifests)))
        rescue Psych::Exception, KeyError, TypeError
          raise Error, "admitted module manifest identity is malformed"
        end

        def external_source_tree_sha256(root)
          root_stat = File.lstat(root)
          unless root_stat.directory? && !root_stat.symlink? && root_stat.uid == Process.uid &&
                 (root_stat.mode & 0o777) == 0o555
            raise Error, "admitted source root is unsafe"
          end
          rows = []
          total = 0
          walk = lambda do |directory, prefix|
            Dir.each_child(directory).sort_by(&:b).each do |name|
              relative = prefix.empty? ? name : File.join(prefix, name)
              path = File.join(directory, name)
              stat = File.lstat(path)
              valid_path = relative.valid_encoding? && !relative.empty? &&
                relative.bytesize <= MAX_EXTERNAL_SOURCE_PATH_BYTES &&
                relative.split("/").none? { |part| part.empty? || part == "." || part == ".." } &&
                relative.count("/") + 1 <= MAX_EXTERNAL_SOURCE_PATH_DEPTH
              raise Error, "admitted source path is unsafe" unless valid_path
              raise Error, "admitted source exceeds its member bound" if
                rows.size >= MAX_EXTERNAL_SOURCE_MEMBERS
              if stat.directory? && !stat.symlink?
                unless stat.uid == Process.uid && (stat.mode & 0o777) == 0o555
                  raise Error, "admitted source directory is unsafe"
                end
                rows << { "kind" => "directory", "mode" => 0o555, "path" => relative }
                walk.call(path, relative)
              else
                unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid &&
                       [ 0o444, 0o555 ].include?(stat.mode & 0o777)
                  raise Error, "admitted source file is unsafe"
                end
                identity = external_regular_file_identity(
                  path, label: "admitted source file", limit: MAX_EXTERNAL_SOURCE_BYTES
                )
                total += identity.fetch("bytesize")
                raise Error, "admitted source exceeds its aggregate byte bound" if
                  total > MAX_EXTERNAL_SOURCE_BYTES
                rows << {
                  "kind" => "file", "mode" => stat.mode & 0o777, "path" => relative,
                  "sha256" => identity.fetch("sha256"), "size" => identity.fetch("bytesize")
                }
              end
            end
          end
          walk.call(root, "")
          raise Error, "admitted source tree is empty" if rows.empty?
          Digest::SHA256.hexdigest(JSON.generate(
            PatrolQualification.canonical_value(rows.sort_by { |row| row.fetch("path") })
          ))
        rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES => e
          raise Error, "admitted source tree is unavailable: #{e.class.name}"
        end

        def setup_process(run_root)
          @env = {
            "HOME" => @hive_home, "HIVE_HOME" => @hive_home,
            "GIT_ATTR_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
            "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_SYSTEM" => "/dev/null",
            "GIT_CONFIG_COUNT" => "4",
            "GIT_CONFIG_KEY_0" => "core.hooksPath", "GIT_CONFIG_VALUE_0" => "/dev/null",
            "GIT_CONFIG_KEY_1" => "commit.gpgsign", "GIT_CONFIG_VALUE_1" => "false",
            "GIT_CONFIG_KEY_2" => "tag.gpgsign", "GIT_CONFIG_VALUE_2" => "false",
            "GIT_CONFIG_KEY_3" => "credential.helper", "GIT_CONFIG_VALUE_3" => "",
            "GIT_TERMINAL_PROMPT" => "0",
            "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
            "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1", "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
            "PATH" => [ File.dirname(RbConfig.ruby), "/usr/bin", "/bin" ].join(":"),
            "TMPDIR" => run_root
          }.freeze
          @process = ChildProcess.new(deadline: @deadline, env: @env)
        end

        def materialize_candidate(run_root)
          sha = git("-C", @repo_root, "rev-parse", "HEAD", label: "resolve candidate").stdout.strip
          raise Error, "candidate HEAD is not a full SHA" unless sha.match?(/\A[0-9a-f]{40}\z/)
          status = git("-C", @repo_root, "status", "--porcelain", "--untracked-files=all",
                       label: "inspect candidate").stdout
          raise Error, "qualification requires a clean candidate checkout" unless status.empty?
          archive = File.join(run_root, "candidate.tar")
          git("-C", @repo_root, "archive", "--format=tar", "--output", archive, sha,
              label: "archive candidate")
          root = File.join(run_root, "candidate")
          FileUtils.mkdir_p(root)
          run("tar", "-xf", archive, "-C", root, label: "materialize candidate")
          executing_controller = PatrolQualification.bounded_read(
            File.expand_path(__FILE__), label: "executing qualification controller", deadline: @deadline
          )
          archived_controller = PatrolQualification.bounded_read(
            File.join(root, "test/e2e/lib/patrol_qualification.rb"),
            label: "archived qualification controller", deadline: @deadline
          )
          unless Digest::SHA256.digest(executing_controller) == Digest::SHA256.digest(archived_controller)
            raise Error, "executing qualification controller differs from the archived candidate"
          end
          captured_head = git("-C", @repo_root, "rev-parse", "HEAD",
                              label: "recheck candidate head").stdout.strip
          captured_status = git("-C", @repo_root, "status", "--porcelain", "--untracked-files=all",
                                label: "recheck candidate cleanliness").stdout
          unless captured_head == sha && captured_status.empty?
            raise Error, "candidate checkout changed while its archive was captured"
          end
          { "sha" => sha, "archive_sha256" => Digest::SHA256.file(archive).hexdigest, "root" => root }
        end

        def install_candidate(candidate, run_root)
          gem_file = File.join(run_root, "candidate.gem")
          run("gem", "build", "hive.gemspec", "--output", gem_file,
              cwd: candidate.fetch("root"), label: "build candidate gem")
          install_root = File.join(run_root, "installed")
          @install_root = install_root
          @candidate_gem_path = gem_file
          installer = File.join(candidate.fetch("root"), "packaging/live_agent_skills/install_candidate_gem.sh")
          run("/bin/bash", installer, gem_file, install_root, label: "install candidate gem")
          @hive_bin = File.join(install_root, "bin", "hive")
          stat = File.lstat(@hive_bin)
          unless stat.file? && !stat.symlink? && File.executable?(@hive_bin)
            raise Error, "candidate installer did not publish a regular bin/hive"
          end
          candidate["gem_sha256"] = Digest::SHA256.file(gem_file).hexdigest
          candidate["installed_hive_sha256"] = Digest::SHA256.file(@hive_bin).hexdigest
        end

        def build_module_catalog(candidate, run_root)
          root = File.join(run_root, "catalog")
          admitted_root = candidate.fetch("source_root", candidate.fetch("root"))
          entries = MODULES.map do |name|
            source = File.join(admitted_root, "modules", name)
            manifest = YAML.safe_load(PatrolQualification.bounded_read(
              File.join(source, "manifest.yml"), label: "catalogue #{name} manifest",
              limit: 1024 * 1024, deadline: @deadline
            ))
            version = manifest.fetch("version")
            destination = File.join(root, "modules", name, version)
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.cp_r(source, destination)
            {
              "name" => name, "version" => version, "latest_version" => version,
              "type" => manifest.fetch("type"), "description" => manifest.fetch("description"),
              "state" => "listed", "discoverable" => true,
              "source_sha" => manifest.dig("source", "revision"),
              "manifest_sha256" => manifest.fetch("release_sha256"),
              "package_path" => "modules/#{name}/#{version}"
            }
          end
          @catalog_manifests = entries.to_h { |entry| [ entry.fetch("name"), entry ] }
          File.binwrite(File.join(root, "catalog.json"), PatrolQualification.canonical(
            "schema" => "honeycomb-catalog/v3", "entries" => entries
          ))
          git("init", "-b", "main", "--quiet", cwd: root, label: "initialize local catalog")
          git("add", "--", ".", cwd: root, label: "stage local catalog")
          git("-c", "user.email=qualification@example.invalid",
              "-c", "user.name=Hive qualification", "-c", "commit.gpgsign=false",
              "commit", "-m", "qualification catalog", "--quiet",
              cwd: root, label: "commit local catalog")
          @catalog_commit = git("rev-parse", "HEAD", cwd: root, label: "resolve local catalog").stdout.strip
          root
        end

        def install_modules(catalog_repo)
          @installed_generations = {}
          rewrite = {
            "GIT_CONFIG_COUNT" => "5",
            "GIT_CONFIG_KEY_4" => "url.file://#{catalog_repo}/.insteadOf",
            "GIT_CONFIG_VALUE_4" => "https://github.com/ivankuznetsov/honeycomb.git"
          }
          MODULES.each do |name|
            version = @catalog_manifests.fetch(name).fetch("version")
            manifest = YAML.safe_load(File.binread(File.join(catalog_repo, "modules", name, version, "manifest.yml")))
            choices = install_choices(manifest)
            source = "honeycomb/#{name}@#{manifest.fetch('version')}"
            preview = JSON.parse(
              hive([ "module", "install", source, "--dry-run", "--json", *choices ],
                   env: rewrite).stdout
            )
            validate_lifecycle!(preview, name:, statuses: [ "preview" ])
            unless preview["preview_receipt"].to_s.match?(/\A[0-9]+\.[0-9a-f]{64}\z/) &&
                   preview["configuration_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
              raise Error, "#{name} module preview identity is malformed"
            end
            expected = {
              "version" => version, "catalog_commit" => @catalog_commit,
              "source_commit" => @catalog_manifests.fetch(name).fetch("source_sha"),
              "manifest_digest" => @catalog_manifests.fetch(name).fetch("manifest_sha256"),
              "configuration_digest" => preview.fetch("configuration_digest")
            }
            apply = JSON.parse(
              hive([ "module", "install", source, "--yes", "--receipt",
                     preview.fetch("preview_receipt"), "--json", *choices ],
                   env: rewrite).stdout
            )
            validate_lifecycle!(apply, name:, statuses: %w[installed already_current])
            validate_generation!(apply.dig("selection", "active"), expected, name:)
            inspected = JSON.parse(hive([ "module", "inspect", name, "--json" ]).stdout)
            validate_inspection!(inspected, name:, expected:)
            @installed_generations[name] = expected.freeze
          end
        end

        def validate_lifecycle!(payload, name:, statuses:)
          valid = payload.is_a?(Hash) &&
            payload["schema"] == "hive-module-lifecycle" &&
            payload["schema_version"] == 1 && payload["ok"] == true &&
            payload["operation"] == "install" && payload["name"] == name &&
            statuses.include?(payload["status"])
          raise Error, "#{name} module lifecycle response is malformed" unless valid
        end

        def validate_generation!(generation, expected, name:)
          unless generation.is_a?(Hash) && generation.keys.sort == expected.keys.sort &&
                 generation == expected
            raise Error, "#{name} installed generation differs from the exact catalogue"
          end
        end

        def validate_inspection!(payload, name:, expected:)
          valid = payload.is_a?(Hash) && payload.keys.sort == %w[modules ok schema schema_version] &&
            payload["schema"] == "hive-module-status" && payload["schema_version"] == 1 &&
            payload["ok"] == true && payload["modules"].is_a?(Array) && payload["modules"].one?
          status = payload.dig("modules", 0)
          valid &&= status.is_a?(Hash) && status["name"] == name &&
            status["lifecycle_state"] == "active" && status["installed"] == true &&
            status["enabled"] == true && status["failure_reason"].nil? &&
            status["integrity"] == {
              "configuration_valid" => true, "generation_present" => true,
              "activation_fenced" => false, "journal_present" => false
            }
          raise Error, "#{name} installed selection is unavailable" unless valid

          validate_generation!(status.fetch("active"), expected, name:)
        end

        def install_choices(manifest)
          settings = manifest.fetch("settings").flat_map do |item|
            [ "--setting", "#{item.fetch('name')}=#{item.fetch('default')}" ]
          end
          hooks = manifest.fetch("hooks").flat_map do |item|
            enabled = item.fetch("id").start_with?("scheduled-") || item.fetch("default_enabled")
            [ "--hook", "#{item.fetch('id')}=#{enabled ? 'enabled' : 'disabled'}" ]
          end
          grants = manifest.fetch("permissions").flat_map do |key, value|
            values = value.is_a?(Array) ? value : [ value ]
            values.map { |item| [ "--grant", "#{key}=#{item}" ] }
          end
          settings + hooks + grants.flatten
        end

        def collect_receipts(catalog, candidate, claim: "u3br")
          reader = ObservationReader.new(project_root: @project_root,
                                         observations_path: @observations_path,
                                         catalog: catalog, deadline: @deadline)
          catalog_digest = Digest::SHA256.hexdigest(catalog.bytes)
          manifest_digest = if claim == "u3c"
            candidate.fetch("module_manifest_sha256")
          else
            Digest::SHA256.hexdigest(MODULES.map { |name|
              File.binread(File.join(candidate.fetch("root"), "modules", name, "manifest.yml"))
            }.join("\0"))
          end
          common = {
            "run_id" => "#{claim}-#{candidate.fetch('sha')[0, 12]}",
            "candidate_sha" => candidate.fetch("sha"),
            "catalog_digest" => catalog_digest,
            "source_digest" => candidate.fetch("archive_sha256"),
            "manifest_digest" => manifest_digest,
            "scenario_manifest_digest" => Digest::SHA256.hexdigest(catalog.bytes + "\0" + reader.bytes),
            "artifacts" => [
              { "kind" => "candidate_archive", "digest" => candidate.fetch("archive_sha256") },
              { "kind" => "scenario_catalog", "digest" => catalog_digest }
            ],
            "reviewer" => claim == "u3c" ? "hive-e2e/u3c-smoke" : "hive-e2e/u3br"
          }
          generated_at = Time.now.utc.iso8601(6)
          prepared = []
          case_results = []
          reader.each do |case_row, observation, record|
            expected = expected_receipt(common, case_row, observation, record, generated_at)
            request = { "selector" => { "module" => case_row.module_name,
                                        "trigger_id" => observation.fetch("trigger_id") },
                        "metadata" => expected.reject { |key, _| %w[receipt_id capture module_projection effects].include?(key) } }
            request.fetch("metadata").delete("schema")
            request.fetch("metadata").delete("schema_version")
            observed = JSON.parse(hive([ "module", "migration", "deterministic-receipt", "--json" ],
                                       stdin_data: JSON.generate(request)).stdout)
            raise Error, "#{case_row.id} public receipt differs from the read-only control" unless
              PatrolQualification.canonical(observed) == PatrolQualification.canonical(expected)
            prepared << [ expected, expected_bindings(expected) ]
            case_results << {
              "id" => case_row.id, "module" => case_row.module_name,
              "fault" => case_row.fault,
              "process_outcomes" => observation.fetch("process_outcomes")
            }
          end
          { "receipts" => prepared.map(&:first), "bindings" => prepared.map(&:last),
            "case_results" => case_results.sort_by { |row| row.fetch("id") },
            "common" => common, "generated_at" => generated_at }
        end

        def expected_receipt(common, case_row, observation, record, generated_at)
          capture = record.fetch("legacy_capture")
          effects = (record.fetch("legacy_effects") + record.fetch("module_effects"))
                    .sort_by { |effect| effect.fetch("receipt_id") }
          repository = { "id" => capture.dig("project", "repository"),
                         "sha" => observation.fetch("repository_sha"),
                         "change_window" => observation.fetch("change_window") }
          payload = common.merge(
            "schema" => "hive-patrol-evidence-receipt", "schema_version" => 1,
            "configuration_digest" => record.fetch("configuration_digest"),
            "repository" => repository, "capture" => capture,
            "module_projection" => record.fetch("module_decision"),
            "decision_class" => case_row.decision_class, "effects" => effects,
            "fault_steps" => case_row.fault == "none" ? [] : [ case_row.fault ],
            "generated_at" => generated_at, "reviewed_at" => generated_at
          )
          payload.merge("receipt_id" => "evidence-#{Digest::SHA256.hexdigest(PatrolQualification.canonical(payload))}")
        end

        def expected_bindings(document)
          capture = document.fetch("capture")
          projection = document.fetch("module_projection")
          document.slice(
            "run_id", "candidate_sha", "catalog_digest", "source_digest", "manifest_digest",
            "configuration_digest", "scenario_manifest_digest", "repository", "receipt_id",
            "decision_class", "fault_steps", "artifacts", "reviewer", "generated_at", "reviewed_at"
          ).merge(
            "capture_id" => capture.fetch("capture_id"),
            "trigger_id" => capture.dig("trigger", "id"),
            "owner_epoch" => capture.fetch("owner_epoch"),
            "module_projection_digest" => Digest::SHA256.hexdigest(PatrolQualification.canonical(projection)),
            "effect_receipt_ids" => document.fetch("effects").map { |effect| effect.fetch("receipt_id") }
          )
        end

        def admit_qualification(prepared)
          report_path = File.join(state_path, "module-runtime", "migration", "report.json")
          report_before = read_report(report_path)
          request = {
            "expected_bindings" => prepared.fetch("bindings"),
            "expected_report_digest" => Digest::SHA256.hexdigest(report_before),
            "generated_at" => prepared.fetch("generated_at"),
            "receipts" => prepared.fetch("receipts")
          }
          report = JSON.parse(
            hive([ "module", "migration", "deterministic-qualification", "--yes", "--json" ],
                 stdin_data: JSON.generate(request)).stdout
          )
          report_after = read_report(report_path)
          unless report_after == PatrolQualification.canonical(report)
            raise Error, "deterministic qualification response differs from the persisted report"
          end
          report
        end

        def read_report(path)
          PatrolQualification.bounded_read(
            path, label: "qualification report", deadline: @deadline
          )
        end

        def proof(candidate, catalog, report, prepared)
          validate_qualification_report!(report, candidate:, catalog:, prepared:)
          lane = report.fetch("lanes").fetch("deterministic")
          raise Error, "reduced deterministic evidence did not qualify" unless lane.fetch("status") == "qualified"
          MODULES.each do |name|
            expected = catalog.expectations.fetch(name).fetch("decision_count")
            raise Error, "qualified #{name} decision count differs" unless
              lane.dig("modules", name, "decision_count") == expected
          end
          case_results = prepared.fetch("case_results").sort_by { |row| row.fetch("id") }
          unless case_results.map { |row| row.fetch("id") } == catalog.cases.map(&:id).sort
            raise Error, "retained case results differ from the qualification catalogue"
          end
          {
            "schema" => "hive-patrol-reduced-qualification-proof", "schema_version" => 1,
            "status" => "qualified_smoke", "candidate_sha" => candidate.fetch("sha"),
            "archive_sha256" => candidate.fetch("archive_sha256"), "gem_sha256" => candidate.fetch("gem_sha256"),
            "installed_hive_sha256" => candidate.fetch("installed_hive_sha256"),
            "catalog_commit" => @catalog_commit, "receipt_count" => prepared.fetch("receipts").size,
            "e2e_case_count" => catalog.cases.size,
            "focused_contract_count" => catalog.contracts.size,
            "case_results" => case_results,
            "qualification_id" => lane.fetch("qualification_id"),
            "claim_fences" => [
              "not_full_u3b", "not_u3c_installed_live", "same_candidate_controls_not_independent",
              "prepared_records_not_fresh_scheduler_matrix"
            ]
          }
        end

        def validate_qualification_report!(report, candidate:, catalog:, prepared:)
          keys = %w[
            blockers candidate_sha generated_at lanes migration report_id
            scenario_manifest_digest schema schema_version status supersedes
          ]
          common = prepared.fetch("common")
          valid = report.is_a?(Hash) && report.keys.sort == keys.sort &&
            report["schema"] == "hive-module-migration-report" &&
            report["schema_version"] == 2 && report["candidate_sha"] == candidate.fetch("sha") &&
            report["scenario_manifest_digest"] == common.fetch("scenario_manifest_digest") &&
            %w[evidence_required qualified].include?(report["status"]) &&
            report["blockers"].is_a?(Array) &&
            report["lanes"].is_a?(Hash) && report["lanes"].keys.sort == %w[deterministic installed_live]
          raise Error, "deterministic qualification report is malformed" unless valid

          lane = report.dig("lanes", "deterministic")
          lane_keys = %w[
            blockers candidate_sha catalog_digest contradiction decision_replay_count
            duplicate_effects effect_count effect_replay_count elapsed_seconds
            evidence_started_at generated_at lane manifest_digest modules qualification_id
            receipt_ids run_id scenario_manifest_digest source_digest status supersedes
            unsettled_effects
          ]
          receipt_ids = prepared.fetch("receipts").map { |receipt| receipt.fetch("receipt_id") }.sort
          valid = lane.is_a?(Hash) && lane.keys.sort == lane_keys.sort &&
            lane["lane"] == "deterministic" && lane["status"] == "qualified" &&
            lane["run_id"] == common.fetch("run_id") &&
            lane["candidate_sha"] == candidate.fetch("sha") &&
            lane["catalog_digest"] == common.fetch("catalog_digest") &&
            lane["source_digest"] == common.fetch("source_digest") &&
            lane["manifest_digest"] == common.fetch("manifest_digest") &&
            lane["scenario_manifest_digest"] == common.fetch("scenario_manifest_digest") &&
            receipt_ids.uniq.size == receipt_ids.size && lane["receipt_ids"] == receipt_ids &&
            lane["modules"].is_a?(Hash) && lane["modules"].keys.sort == MODULES.sort &&
            lane["blockers"] == [] &&
            lane["duplicate_effects"] == [] && lane["unsettled_effects"] == []
          raise Error, "deterministic qualification lane differs from this campaign" unless valid

          MODULES.each do |name|
            receipts = prepared.fetch("receipts").select do |receipt|
              receipt.dig("module_projection", "module") == name
            end
            summary = lane.dig("modules", name)
            expected = catalog.expectations.fetch(name)
            summary_keys = %w[
              blockers change_windows configuration_digest decision_classes
              decision_count decision_identities elapsed_seconds repository_shas
            ]
            configurations = receipts.map { |row| row.fetch("configuration_digest") }.uniq
            valid = summary.is_a?(Hash) && summary.keys.sort == summary_keys.sort &&
              summary["decision_count"] == receipts.size &&
              summary["decision_count"] == expected.fetch("decision_count") &&
              summary["decision_identities"].is_a?(Array) &&
              summary["decision_identities"].size == receipts.size &&
              summary["decision_identities"].uniq.size == receipts.size &&
              summary["decision_identities"].all? { |id| id.to_s.match?(/\Adecision-[0-9a-f]{64}\z/) } &&
              summary["decision_classes"] == receipts.map { |row| row.fetch("decision_class") }.uniq.sort &&
              summary["repository_shas"] == receipts.map { |row| row.dig("repository", "sha") }.uniq.sort &&
              summary["change_windows"] == receipts.map { |row| row.dig("repository", "change_window") }.uniq.sort &&
              configurations.one? && summary["configuration_digest"] == configurations.first &&
              summary["blockers"] == []
            raise Error, "qualified #{name} summary differs from this campaign" unless valid
          end

          qualification_id = "qualification-#{Digest::SHA256.hexdigest(
            PatrolQualification.canonical(lane.reject { |key, _| key == "qualification_id" })
          )}"
          report_id = "report-#{Digest::SHA256.hexdigest(
            PatrolQualification.canonical(report.reject { |key, _| key == "report_id" })
          )}"
          unless lane["qualification_id"] == qualification_id && report["report_id"] == report_id
            raise Error, "deterministic qualification identity differs from its contents"
          end
        end

        def write_evidence(value)
          redacted = redact(value)
          bytes = PatrolQualification.canonical(redacted)
          raise Error, "qualification evidence exceeds its bound" if bytes.bytesize > MAX_EVIDENCE_BYTES
          if Hive::SecretPatterns.scan(bytes).any?
            raise Error, "qualification evidence contains a secret pattern"
          end
          FileUtils.mkdir_p(@evidence_root, mode: 0o700)
          path = File.join(@evidence_root, "patrol-u3br-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.json")
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
          path
        end

        def redact(value)
          case value
          when Hash
            value.to_h do |key, child|
              redacted_key = Hive::SecretPatterns.redact(key.to_s)
              redacted_child = if key.to_s.match?(/token|secret|password|credential/i)
                "[REDACTED]"
              else
                redact(child)
              end
              [ redacted_key, redacted_child ]
            end
          when Array then value.map { |child| redact(child) }
          when String then Hive::SecretPatterns.redact(value)
          else value
          end
        end

        def state_path
          config = YAML.safe_load(PatrolQualification.bounded_read(
            File.join(@project_root, ".hive-state", "config.yml"),
            label: "qualification project config", deadline: @deadline
          )) || {}
          File.expand_path(config.fetch("hive_state_path", ".hive-state"), @project_root)
        end

        def hive(args, stdin_data: "", env: {})
          run(@hive_bin, *args, cwd: @project_root, stdin_data: stdin_data, env: env,
              label: "installed hive #{args.first(3).join(' ')}")
        end

        def run(*command, label:, cwd: @repo_root, stdin_data: "", env: {})
          process = env.empty? ? @process : ChildProcess.new(deadline: @deadline, env: @env.merge(env))
          process.run(*command, label: label, cwd: cwd, stdin_data: stdin_data, timeout: @child_timeout)
        end

        def git(*arguments, **options)
          run("git", *GIT_OVERRIDES, *arguments, **options)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
