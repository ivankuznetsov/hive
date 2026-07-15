require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module Hive
  module RefactorPatrol
    # Durable lifecycle for cadence-owned, one-PR-at-a-time architecture runs.
    # This store is deliberately separate from both ordinary patrol state and
    # the refactor-patrol command's global thesis/fingerprint state.
    class PostMergeStateStore
      SCHEMA_VERSION = 1
      STATES = %w[owed running blocked processed].freeze
      ATTEMPT_STATES = %w[running failed blocked processed].freeze
      MAX_REASON_BYTES = 500
      MAX_EVIDENCE_BYTES = 2_000

      class StateError < Hive::Error
        def exit_code
          Hive::ExitCodes::TEMPFAIL
        end
      end

      attr_reader :project_root, :project, :root

      def initialize(project_root, project: nil)
        @project_root = File.expand_path(project_root)
        @project = (project || File.basename(@project_root)).to_s
        @root = File.join(@project_root, ".hive-state", "refactor_patrol", "post_merge")
      end

      def initialize_at!(head_sha:, now: Time.now, capability_merge_sha: nil,
                         capability_merge_ancestor: nil)
        return state if File.exist?(state_path)

        sha = required_string(head_sha, "head_sha")
        doc = {
          "schema_version" => SCHEMA_VERSION,
          "project" => project,
          "project_root" => canonical_project_root,
          "initial_sha" => sha,
          "checkpoint_sha" => sha,
          "active_batch_head" => nil,
          "active_batch_start_index" => nil,
          "initialized_at" => iso8601(now),
          "updated_at" => iso8601(now),
          "merges" => [],
          "diagnostics" => {}
        }
        if capability_merge_sha
          doc["diagnostics"]["capability_merge_sha"] = capability_merge_sha.to_s
          doc["diagnostics"]["capability_merge_ancestor"] = capability_merge_ancestor unless capability_merge_ancestor.nil?
        end
        write_json(state_path, doc)
      end

      def state
        doc = read_state!
        reconcile!(doc)
      end

      def initialized?
        File.file?(state_path)
      end

      def active_batch?
        initialized? && !state["active_batch_head"].nil?
      end

      def load!(head_sha:, ancestor_check:)
        doc = state
        reachable = ancestor_check.call(doc.fetch("checkpoint_sha"), required_string(head_sha, "head_sha"))
        raise StateError, "post-merge checkpoint is not reachable from the registered trunk" unless reachable

        doc
      rescue StateError
        raise
      rescue StandardError => e
        raise StateError, "post-merge checkpoint validation failed: #{e.class}: #{e.message}"
      end

      def open_batch!(head_sha:, merges:, diagnostics: [], now: Time.now)
        doc = state
        head = required_string(head_sha, "head_sha")
        doc["active_batch_start_index"] = doc.fetch("merges").length if doc["active_batch_head"].nil?
        doc["active_batch_head"] = head
        reopen_blocked_in(doc, now: now)

        Array(merges).each do |candidate|
          normalized = normalize_merge(candidate, now: now)
          existing = doc.fetch("merges").find { |item| item.fetch("identity") == normalized.fetch("identity") }
          if existing
            assert_same_merge!(existing, normalized)
          else
            doc.fetch("merges") << normalized
          end
        end
        doc["diagnostics"]["catalog"] = bounded_evidence(Array(diagnostics)) unless Array(diagnostics).empty?
        doc["updated_at"] = iso8601(now)
        advance_checkpoint_in!(doc, now: now)
        write_json(state_path, doc)
      end

      def reopen_blocked!(now: Time.now)
        doc = state
        reopen_blocked_in(doc, now: now)
        doc["updated_at"] = iso8601(now)
        write_json(state_path, doc)
      end

      def owed_merges
        state.fetch("merges").select { |item| item.fetch("status") == "owed" }
      end

      def merge_record(identity)
        record = find_merge!(state, identity)
        deep_dup(record)
      end

      def reserve!(identity, fingerprint_snapshot:, now: Time.now)
        doc = state
        record = find_merge!(doc, identity)
        unless %w[owed blocked].include?(record.fetch("status"))
          raise StateError, "post-merge #{identity} cannot be reserved from #{record.fetch('status')}"
        end

        record["fingerprint_snapshot"] ||= deep_dup(fingerprint_snapshot || {})
        attempt = {
          "number" => record.fetch("attempts").length + 1,
          "status" => "running",
          "started_at" => iso8601(now),
          "finished_at" => nil,
          "reason" => nil,
          "evidence" => nil
        }
        record.fetch("attempts") << attempt
        record["status"] = "running"
        record["updated_at"] = iso8601(now)
        doc["updated_at"] = iso8601(now)
        write_json(state_path, doc)
        deep_dup(record)
      end

      def record_failure!(identity, reason:, evidence: nil, now: Time.now)
        finish_attempt!(identity, status: "failed", merge_status: "owed", reason: reason, evidence: evidence, now: now)
      end

      def record_blocked!(identity, reason:, evidence: nil, now: Time.now)
        finish_attempt!(identity, status: "blocked", merge_status: "blocked", reason: reason, evidence: evidence, now: now)
      end

      def record_skip!(identity, reason:, evidence: nil, now: Time.now)
        doc = state
        record = find_merge!(doc, identity)
        unless %w[owed blocked].include?(record.fetch("status"))
          raise StateError, "post-merge #{identity} cannot be blocked from #{record.fetch('status')}"
        end

        record.fetch("attempts") << {
          "number" => record.fetch("attempts").length + 1,
          "status" => "blocked",
          "started_at" => iso8601(now),
          "finished_at" => iso8601(now),
          "reason" => bounded_reason(reason),
          "evidence" => bounded_evidence(evidence)
        }
        record["status"] = "blocked"
        record["updated_at"] = iso8601(now)
        doc["updated_at"] = iso8601(now)
        write_json(state_path, doc)
      end

      def cancel_reservation!(identity, reason:, evidence: nil, now: Time.now)
        finish_attempt!(identity, status: "failed", merge_status: "owed", reason: reason, evidence: evidence, now: now)
      end

      def recover_interrupted!(now: Time.now)
        doc = state
        changed = false
        doc.fetch("merges").each do |record|
          next unless record.fetch("status") == "running"

          attempt = record.fetch("attempts").last
          next unless attempt && attempt.fetch("status") == "running"

          attempt["status"] = "failed"
          attempt["finished_at"] = iso8601(now)
          attempt["reason"] = "daemon_restarted"
          record["status"] = "owed"
          record["updated_at"] = iso8601(now)
          changed = true
        end
        if changed
          doc["updated_at"] = iso8601(now)
          write_json(state_path, doc)
        end
        doc
      end

      def persist_artifacts!(identity, report:, emission_digests:)
        doc = state
        record = find_merge!(doc, identity)
        normalized = normalize_report(report, record)
        path = report_path(record)
        write_json(path, normalized)

        ledger = read_emissions!
        ledger.fetch("entries")[identity] = {
          "report_digest" => Digest::SHA256.hexdigest(JSON.generate(normalized)),
          "digests" => deep_dup(emission_digests || {}),
          "updated_at" => normalized.fetch("completed_at")
        }
        write_json(emissions_path, ledger)
        normalized
      end

      def complete!(identity, report:, emission_digests:, now: Time.now)
        persist_artifacts!(identity, report: report, emission_digests: emission_digests)
        doc = state # reconciliation performs success + checkpoint writes in order
        record = find_merge!(doc, identity)
        unless record.fetch("status") == "processed"
          raise StateError, "post-merge completion artifacts for #{identity} could not be reconciled"
        end

        deep_dup(record)
      end

      def emissions
        deep_dup(read_emissions!.fetch("entries"))
      end

      def report_path(record_or_identity)
        record = record_or_identity.is_a?(Hash) ? record_or_identity : find_merge!(state, record_or_identity)
        File.join(root, "reports", "pr-#{record.fetch('pr_number')}-#{record.fetch('merge_sha')}.json")
      end

      def identity_for(pr_number, merge_sha)
        "pr-#{Integer(pr_number)}-#{required_string(merge_sha, 'merge_sha')}"
      rescue ArgumentError, TypeError
        raise StateError, "invalid post-merge PR identity"
      end

      private

      def state_path
        File.join(root, "state.json")
      end

      def emissions_path
        File.join(root, "emissions.json")
      end

      def canonical_project_root
        File.realpath(project_root)
      rescue SystemCallError
        project_root
      end

      def read_state!
        raise StateError, "post-merge state is not initialized" unless File.exist?(state_path)

        doc = JSON.parse(File.read(state_path))
        validate_state!(doc)
        doc
      rescue StateError
        raise
      rescue JSON::ParserError, SystemCallError => e
        raise StateError, "post-merge state is unreadable: #{e.message}"
      end

      def validate_state!(doc)
        raise StateError, "post-merge state must be a JSON object" unless doc.is_a?(Hash)
        version = doc["schema_version"]
        raise StateError, "unsupported post-merge state version #{version.inspect}" unless version == SCHEMA_VERSION
        raise StateError, "post-merge state project identity mismatch" unless doc["project"] == project
        raise StateError, "post-merge state root identity mismatch" unless doc["project_root"] == canonical_project_root

        %w[initial_sha checkpoint_sha initialized_at updated_at].each do |key|
          required_string(doc[key], key)
        end
        raise StateError, "post-merge merges must be an array" unless doc["merges"].is_a?(Array)
        raise StateError, "post-merge diagnostics must be an object" unless doc["diagnostics"].is_a?(Hash)

        identities = {}
        doc.fetch("merges").each do |record|
          validate_merge!(record)
          identity = record.fetch("identity")
          raise StateError, "duplicate post-merge identity #{identity}" if identities[identity]

          identities[identity] = true
        end
        validate_batch!(doc)
        true
      end

      def validate_merge!(record)
        raise StateError, "post-merge record must be an object" unless record.is_a?(Hash)
        expected = identity_for(record["pr_number"], record["merge_sha"])
        raise StateError, "post-merge record identity mismatch" unless record["identity"] == expected
        required_string(record["base_sha"], "base_sha")
        raise StateError, "invalid post-merge status" unless STATES.include?(record["status"])
        raise StateError, "post-merge attempts must be an array" unless record["attempts"].is_a?(Array)
        record.fetch("attempts").each do |attempt|
          raise StateError, "invalid post-merge attempt" unless ATTEMPT_STATES.include?(attempt["status"])
        end
      rescue KeyError => e
        raise StateError, "post-merge record missing #{e.key}"
      end

      def validate_batch!(doc)
        head = doc["active_batch_head"]
        index = doc["active_batch_start_index"]
        if head.nil?
          raise StateError, "inactive post-merge batch has a start index" unless index.nil?
        elsif !index.is_a?(Integer) || index.negative? || index > doc.fetch("merges").length
          raise StateError, "active post-merge batch has an invalid start index"
        end
      end

      def normalize_merge(candidate, now:)
        source = candidate.transform_keys(&:to_s)
        pr = Integer(source.fetch("pr_number"))
        sha = required_string(source.fetch("merge_sha"), "merge_sha")
        {
          "identity" => identity_for(pr, sha),
          "pr_number" => pr,
          "merge_sha" => sha,
          "base_sha" => required_string(source.fetch("base_sha"), "base_sha"),
          "subject" => source["subject"].to_s,
          "changed_paths" => Array(source["changed_paths"]).map(&:to_s),
          "status" => "owed",
          "attempts" => [],
          "fingerprint_snapshot" => nil,
          "report_path" => nil,
          "created_at" => iso8601(now),
          "updated_at" => iso8601(now)
        }
      rescue KeyError, ArgumentError, TypeError => e
        raise StateError, "invalid post-merge catalog record: #{e.message}"
      end

      def assert_same_merge!(existing, candidate)
        %w[pr_number merge_sha base_sha].each do |key|
          next if existing[key] == candidate[key]

          raise StateError, "post-merge identity #{existing.fetch('identity')} changed #{key}"
        end
      end

      def finish_attempt!(identity, status:, merge_status:, reason:, evidence:, now:)
        doc = state
        record = find_merge!(doc, identity)
        attempt = record.fetch("attempts").last
        unless record.fetch("status") == "running" && attempt && attempt.fetch("status") == "running"
          raise StateError, "post-merge #{identity} has no running attempt"
        end

        attempt["status"] = status
        attempt["finished_at"] = iso8601(now)
        attempt["reason"] = bounded_reason(reason)
        attempt["evidence"] = bounded_evidence(evidence)
        record["status"] = merge_status
        record["updated_at"] = iso8601(now)
        doc["updated_at"] = iso8601(now)
        write_json(state_path, doc)
        deep_dup(record)
      end

      def reconcile!(doc)
        changed = false
        ledger = read_emissions!
        doc.fetch("merges").each do |record|
          next if record.fetch("status") == "processed"

          report = reconciliation_report(record, ledger)
          next unless report

          attempt = record.fetch("attempts").last
          if attempt&.fetch("status", nil) == "running"
            attempt["status"] = "processed"
            attempt["finished_at"] = report.fetch("completed_at")
          end
          record["status"] = "processed"
          record["report_path"] = relative_report_path(record)
          record["updated_at"] = report.fetch("completed_at")
          doc["updated_at"] = report.fetch("completed_at")
          write_json(state_path, doc) # success is durable before checkpoint advancement
          changed = true
        end
        changed = advance_checkpoint_in!(doc, now: Time.now) || changed
        write_json(state_path, doc) if changed
        doc
      end

      def reconciliation_report(record, ledger)
        path = report_path(record)
        entry = ledger.fetch("entries")[record.fetch("identity")]
        return nil unless entry && File.file?(path)

        report = JSON.parse(File.read(path))
        return nil unless report.is_a?(Hash) && report["completion_status"] == "success"
        return nil unless report["project"] == project
        return nil unless report["project_root"] == canonical_project_root
        return nil unless report["pr_number"] == record["pr_number"]
        return nil unless report["merge_sha"] == record["merge_sha"]
        return nil unless report["base_sha"] == record["base_sha"]
        return nil unless entry["report_digest"] == Digest::SHA256.hexdigest(JSON.generate(report))

        report
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def advance_checkpoint_in!(doc, now:)
        return false unless doc["active_batch_head"]

        start = doc.fetch("active_batch_start_index")
        active = doc.fetch("merges")[start..] || []
        contiguous = active.take_while { |record| record.fetch("status") == "processed" }
        old_checkpoint = doc.fetch("checkpoint_sha")
        if contiguous.length == active.length
          doc["checkpoint_sha"] = doc.fetch("active_batch_head")
          doc["active_batch_head"] = nil
          doc["active_batch_start_index"] = nil
        elsif !contiguous.empty?
          doc["checkpoint_sha"] = contiguous.last.fetch("merge_sha")
        end
        changed = doc.fetch("checkpoint_sha") != old_checkpoint || doc["active_batch_head"].nil?
        doc["updated_at"] = iso8601(now) if changed
        changed
      end

      def reopen_blocked_in(doc, now:)
        doc.fetch("merges").each do |record|
          next unless record.fetch("status") == "blocked"

          record["status"] = "owed"
          record["updated_at"] = iso8601(now)
        end
      end

      def normalize_report(report, record)
        report.transform_keys(&:to_s).merge(
          "schema" => "hive-refactor-patrol-post-merge",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol-post-merge", SCHEMA_VERSION),
          "project" => project,
          "project_root" => canonical_project_root,
          "pr_number" => record.fetch("pr_number"),
          "merge_sha" => record.fetch("merge_sha"),
          "base_sha" => record.fetch("base_sha")
        )
      end

      def read_emissions!
        return { "schema_version" => SCHEMA_VERSION, "entries" => {} } unless File.exist?(emissions_path)

        doc = JSON.parse(File.read(emissions_path))
        unless doc.is_a?(Hash) && doc["schema_version"] == SCHEMA_VERSION && doc["entries"].is_a?(Hash)
          raise StateError, "post-merge emission ledger is malformed or unsupported"
        end
        doc
      rescue StateError
        raise
      rescue JSON::ParserError, SystemCallError => e
        raise StateError, "post-merge emission ledger is unreadable: #{e.message}"
      end

      def find_merge!(doc, identity)
        record = doc.fetch("merges").find { |item| item.fetch("identity") == identity.to_s }
        raise StateError, "unknown post-merge identity #{identity}" unless record

        record
      end

      def relative_report_path(record)
        File.join("reports", "pr-#{record.fetch('pr_number')}-#{record.fetch('merge_sha')}.json")
      end

      def write_json(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.write(tmp, "#{JSON.pretty_generate(data)}\n")
        File.rename(tmp, path)
        deep_dup(data)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def required_string(value, name)
        text = value.to_s
        raise StateError, "#{name} must be present" if text.empty?

        text
      end

      def bounded_reason(reason)
        reason.to_s.byteslice(0, MAX_REASON_BYTES)
      end

      def bounded_evidence(evidence)
        return nil if evidence.nil?

        JSON.parse(JSON.generate(evidence).byteslice(0, MAX_EVIDENCE_BYTES))
      rescue JSON::ParserError
        { "summary" => JSON.generate(evidence).byteslice(0, MAX_EVIDENCE_BYTES - 20) }
      end

      def iso8601(time)
        time.utc.iso8601
      end

      def deep_dup(value)
        Marshal.load(Marshal.dump(value))
      end
    end
  end
end
