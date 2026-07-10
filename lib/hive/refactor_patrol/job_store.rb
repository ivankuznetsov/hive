require "json"
require "fileutils"
require "digest"
require "time"
require "hive/atomic_file"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module RefactorPatrol
    # Authoritative v2 lifecycle storage. A job aggregate owns discovery and
    # action receipts; the indexes below are disposable projections rebuilt by
    # scanning terminal aggregates.
    class JobStore
      SCHEMA = "hive-refactor-patrol-job".freeze
      SCHEMA_VERSION = 2
      ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
      STATES = %w[queued analyzing classified acting blocked complete].freeze
      DISPOSITIONS = %w[accepted flagged suppressed].freeze
      ZERO_REASONS = %w[no_mapped_slice no_theses all_suppressed].freeze
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id source analysis_sha policy state complete
        dispositions feature_results review_errors zero_reason attempts actions
        created_at updated_at
      ].freeze
      SOURCE_KEYS = %w[
        url number repository registration base_branch base_sha merge_sha
        merged_at changed_paths manifest_checksum
      ].freeze
      POLICY_KEYS = %w[discovery auto_fix issue_filing epoch captured_at].freeze
      DISPOSITION_KEYS = %w[id feature_id fingerprint score admissible reasons reference].freeze
      FEATURE_RESULT_KEYS = %w[feature_id complete thesis_ids errors].freeze
      ACTION_KEYS = %w[
        canonical_action_id thesis_id thesis_fingerprint kind owner_job_id
        outcome terminal receipts
      ].freeze

      class Error < StandardError
        attr_reader :path

        def initialize(message, path: nil)
          @path = path
          super(path ? "#{message}: #{path}" : message)
        end
      end

      class CorruptRecord < Error; end
      class UnsupportedVersion < Error; end
      class InconsistentRecord < Error; end
      class RecordNotFound < Error; end
      class StaleClaim < Error; end

      DISCOVERY_ATTEMPT_KIND = "discovery_claim".freeze
      ACTIVE_CLAIM_STATES = %w[claimed running].freeze

      attr_reader :project_root, :root

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        @root = File.join(@project_root, ".hive-state", "refactor_patrol", "v2")
      end

      # Intake is the only bridge from an immutable PR manifest to the
      # authoritative lifecycle aggregate. The per-job lock makes duplicate
      # watcher/reconciler producers preserve the first policy snapshot and
      # timestamp instead of racing two otherwise equivalent queued writes.
      def enqueue_manifest!(manifest, policy:, now: Time.now, dry_run: false)
        data = json_copy(manifest)
        source = source_from_manifest(data)
        aggregate = queued_aggregate(
          job_id: data.fetch("job_id"),
          source: source,
          policy: json_copy(policy),
          now: now
        )
        validate_job!(aggregate)
        return aggregate if dry_run

        path = job_path(aggregate.fetch("job_id"))
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          if File.file?(path)
            existing = read_job(aggregate.fetch("job_id"))
            unless existing.fetch("source") == source
              quarantine_job_source!(
                aggregate.fetch("job_id"),
                authoritative: existing.fetch("source"),
                candidate: source
              )
              raise InconsistentRecord.new("refactor patrol intake source is immutable", path: path)
            end
            return existing
          end

          atomic_write(path, aggregate)
        end
        aggregate
      rescue KeyError => e
        raise CorruptRecord, "refactor patrol manifest is missing #{e.key.inspect}"
      end

      # Expose independently due intake jobs so one old backoff-bound
      # occurrence cannot hide later work.
      def eligible_jobs(now: Time.now)
        eligible_from(jobs, now: now).sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError => e
        raise InconsistentRecord, "refactor patrol job has invalid scheduling timestamp (#{e.message})"
      end

      def eligible_from(records, now:)
        records.select do |aggregate|
          next false if aggregate.fetch("complete")
          next false unless %w[queued blocked].include?(aggregate.fetch("state"))

          deadline = aggregate.fetch("attempts").reverse_each.filter_map { |attempt| attempt["next_eligible_at"] }.first
          deadline.nil? || Time.iso8601(deadline) <= now
        end
      end
      private :eligible_from

      # Includes an expired analyzing claim so a restarted daemon can prove
      # the prior process group gone (or terminate it) before fencing a new
      # generation. The claim CAS remains authoritative.
      def claimable_jobs(now: Time.now)
        records = jobs
        (eligible_from(records, now: now) + records.select do |aggregate|
          next false unless aggregate.fetch("state") == "analyzing"

          attempt = active_discovery_attempt(aggregate)
          attempt && Time.iso8601(attempt.fetch("expires_at")) <= now
        end).uniq { |aggregate| aggregate.fetch("job_id") }
          .sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol claim has invalid scheduling evidence (#{e.message})"
      end

      def claim_discovery!(job_id, owner:, analysis_sha:, now: Time.now, lease_sec: 3600,
                           claim_resolver: nil, owner_pid: nil, owner_process_start_time: nil)
        mutate_job(job_id) do |aggregate, path|
          return nil if aggregate.fetch("complete")

          active = active_discovery_attempt(aggregate)
          if active
            return nil if Time.iso8601(active.fetch("expires_at")) > now
            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            return nil unless resolved == :resolved

            active["state"] = "superseded"
            active["finished_at"] = now.utc.iso8601
            active["outcome"] = "expired_claim_resolved"
          end

          pinned = aggregate["analysis_sha"]
          if pinned && pinned != analysis_sha.to_s
            raise InconsistentRecord.new("refactor patrol analysis checkout changed after pin", path: path)
          end
          generation = aggregate.fetch("attempts").filter_map { |attempt| attempt["generation"] }.max.to_i + 1
          timestamp = now.utc.iso8601
          attempt = {
            "kind" => DISCOVERY_ATTEMPT_KIND,
            "owner" => owner.to_s,
            "owner_pid" => owner_pid,
            "owner_process_start_time" => owner_process_start_time,
            "generation" => generation,
            "state" => "claimed",
            "claimed_at" => timestamp,
            "heartbeat_at" => timestamp,
            "expires_at" => (now + lease_sec.to_i).utc.iso8601,
            "pid" => nil,
            "process_start_time" => nil,
            "pgid" => nil,
            "finished_at" => nil,
            "outcome" => nil,
            "next_eligible_at" => nil
          }
          aggregate["analysis_sha"] ||= analysis_sha.to_s
          aggregate["state"] = "analyzing"
          aggregate["complete"] = false
          aggregate.fetch("attempts") << attempt
          aggregate["updated_at"] = timestamp
          [ aggregate, claim_token(aggregate, attempt) ]
        end
      end

      def attach_discovery_process!(token, pid:, process_start_time:, pgid:, now: Time.now)
        mutate_claim(token) do |aggregate, attempt|
          if pid.to_i <= 1 || pgid.to_i <= 1 || process_start_time.to_s.empty?
            raise InconsistentRecord, "refactor patrol child identity is incomplete"
          end
          attempt["state"] = "running"
          attempt["pid"] = pid.to_i
          attempt["process_start_time"] = process_start_time.to_s
          attempt["pgid"] = pgid.to_i
          attempt["heartbeat_at"] = now.utc.iso8601
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      def release_discovery!(token, reason:, now: Time.now, backoff_sec: 60)
        mutate_claim(token) do |aggregate, attempt|
          timestamp = now.utc.iso8601
          attempt["state"] = "released"
          attempt["finished_at"] = timestamp
          attempt["outcome"] = reason.to_s
          attempt["next_eligible_at"] = (now + backoff_sec.to_i).utc.iso8601
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["review_errors"] = []
          aggregate["zero_reason"] = nil
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      # Checkout/identity failures before a claim still need durable evidence
      # and retry throttling; otherwise the daemon would repeat shell/network
      # probes and identical log lines on every fast tick.
      def block_discovery!(job_id, reason:, evidence: {}, now: Time.now, backoff_sec: 60)
        mutate_job(job_id) do |aggregate, _path|
          next aggregate if aggregate.fetch("complete")

          timestamp = now.utc.iso8601
          aggregate.fetch("attempts") << {
            "kind" => "discovery_block",
            "state" => "blocked",
            "reason" => reason.to_s,
            "evidence" => json_copy(evidence),
            "finished_at" => timestamp,
            "next_eligible_at" => (now + backoff_sec.to_i).utc.iso8601
          }
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def checkpoint_discovery!(token, envelope:, now: Time.now)
        payload = json_copy(envelope)
        mutate_claim(token) do |aggregate, attempt|
          assert_matching_discovery_payload!(aggregate, payload)
          aggregate["dispositions"] = DISPOSITIONS.to_h { |name| [ name, payload.fetch(name) ] }
          aggregate["feature_results"] = []
          aggregate["review_errors"] = []
          aggregate["zero_reason"] = payload.fetch("zero_reason")
          terminal = !action_authorized_for?(aggregate, payload)
          aggregate["state"] = terminal ? "complete" : "classified"
          aggregate["complete"] = terminal
          attempt["state"] = "complete"
          attempt["finished_at"] = now.utc.iso8601
          attempt["outcome"] = terminal ? "complete" : "classified"
          attempt["next_eligible_at"] = nil
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      def write_job!(aggregate, dry_run: false)
        data = json_copy(aggregate)
        validate_job!(data)
        return data if dry_run

        path = job_path(data.fetch("job_id"))
        if File.exist?(path)
          existing = read_job(data.fetch("job_id"))
          validate_transition!(existing, data, path)
        end
        atomic_write(path, data)
        data
      end

      def read_job(job_id)
        id = validate_id!(job_id)
        path = job_path(id)
        raise RecordNotFound.new("refactor patrol job not found", path: path) unless File.file?(path)

        read_job_path(path, expected_job_id: id)
      end

      def jobs
        each_job.to_a
      end

      def each_job
        return enum_for(__method__) unless block_given?
        return unless Dir.exist?(jobs_dir)

        Dir.glob(File.join(jobs_dir, "*.json")).sort.each do |path|
          yield read_job_path(path, expected_job_id: File.basename(path, ".json"))
        end
      end

      def rebuild_indexes!
        fingerprint_entries = {}
        owner_actions = {}
        action_links = []

        each_job do |aggregate|
          next unless aggregate.fetch("complete") == true

          job_id = aggregate.fetch("job_id")
          DISPOSITIONS.each do |disposition|
            aggregate.fetch("dispositions").fetch(disposition).each do |item|
              fingerprint = item.fetch("fingerprint")
              entry = fingerprint_entries[fingerprint] ||= {
                "occurrences" => [],
                "canonical_action_ids" => []
              }
              entry.fetch("occurrences") << {
                "job_id" => job_id,
                "thesis_id" => item.fetch("id"),
                "disposition" => disposition
              }
            end
          end

          aggregate.fetch("actions").select { |action| action.fetch("terminal") == true }.each do |action|
            action_id = action.fetch("canonical_action_id")
            if action.fetch("owner_job_id") == job_id
              if owner_actions.key?(action_id)
                raise InconsistentRecord, "canonical action #{action_id.inspect} has multiple owner jobs"
              end
              owner_actions[action_id] = {
                "owner_job_id" => job_id,
                "kind" => action.fetch("kind"),
                "thesis_fingerprint" => action.fetch("thesis_fingerprint"),
                "outcome" => action.fetch("outcome")
              }
            else
              action_links << [ action_id, action.fetch("owner_job_id") ]
            end

            fingerprint_entries[action.fetch("thesis_fingerprint")] ||= {
              "occurrences" => [],
              "canonical_action_ids" => []
            }
            fingerprint_entries.fetch(action.fetch("thesis_fingerprint"))
                               .fetch("canonical_action_ids") << action_id
          end
        end

        action_links.each do |action_id, owner_job_id|
          owner = owner_actions[action_id]
          unless owner && owner.fetch("owner_job_id") == owner_job_id
            raise InconsistentRecord,
                  "canonical action #{action_id.inspect} links to missing owner job #{owner_job_id.inspect}"
          end
        end

        fingerprint_entries.each_value do |entry|
          entry.fetch("occurrences").sort_by! { |item| [ item.fetch("job_id"), item.fetch("thesis_id") ] }
          entry["canonical_action_ids"] = entry.fetch("canonical_action_ids").uniq.sort
        end
        fingerprints = {
          "schema" => "hive-refactor-patrol-fingerprint-index",
          "schema_version" => SCHEMA_VERSION,
          "fingerprints" => fingerprint_entries.sort.to_h
        }
        actions = {
          "schema" => "hive-refactor-patrol-action-index",
          "schema_version" => SCHEMA_VERSION,
          "actions" => owner_actions.sort.to_h
        }
        atomic_write(fingerprint_index_path, fingerprints)
        atomic_write(action_index_path, actions)
        { "fingerprints" => fingerprints, "actions" => actions }
      end

      def fingerprint_index
        read_derived_index(
          fingerprint_index_path,
          schema: "hive-refactor-patrol-fingerprint-index",
          collection: "fingerprints"
        ) { rebuild_indexes!.fetch("fingerprints") }
      end

      def action_index
        read_derived_index(
          action_index_path,
          schema: "hive-refactor-patrol-action-index",
          collection: "actions"
        ) { rebuild_indexes!.fetch("actions") }
      end

      def fingerprint_index_path
        File.join(root, "indexes", "fingerprints.json")
      end

      def action_index_path
        File.join(root, "indexes", "actions.json")
      end

      private

      def scheduling_key(aggregate)
        source = aggregate.fetch("source")
        merged_at = source["merged_at"] ? Time.iso8601(source.fetch("merged_at")).utc : Time.at(0).utc
        [ merged_at, source.fetch("number"), source.fetch("merge_sha"), aggregate.fetch("job_id") ]
      end

      def active_discovery_attempt(aggregate)
        aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == DISCOVERY_ATTEMPT_KIND && ACTIVE_CLAIM_STATES.include?(attempt["state"])
        end
      end

      def claim_token(aggregate, attempt)
        {
          job_id: aggregate.fetch("job_id"), owner: attempt.fetch("owner"),
          generation: attempt.fetch("generation")
        }
      end

      def mutate_claim(token)
        mutate_job(token.fetch(:job_id)) do |aggregate, path|
          attempt = active_discovery_attempt(aggregate)
          unless attempt && attempt["owner"] == token.fetch(:owner).to_s &&
                 attempt["generation"] == token.fetch(:generation).to_i
            raise StaleClaim.new("refactor patrol claim fence is stale", path: path)
          end
          yield aggregate, attempt
        end
      end

      def mutate_job(job_id)
        path = job_path(validate_id!(job_id))
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          existing = read_job(job_id)
          aggregate = json_copy(existing)
          result = yield aggregate, path
          replacement, return_value = result.is_a?(Array) ? result : [ result, result ]
          validate_job!(replacement, path: path)
          validate_transition!(existing, replacement, path)
          atomic_write(path, replacement)
          return return_value
        end
      end

      def assert_matching_discovery_payload!(aggregate, payload)
        unless payload.is_a?(Hash) && payload["schema"] == "hive-refactor-patrol" &&
               payload["schema_version"] == SCHEMA_VERSION && payload["ok"] == true &&
               payload["complete"] == true && payload["job_id"] == aggregate.fetch("job_id") &&
               payload["project"] == aggregate.dig("source", "registration") &&
               payload["project_root"] == project_root && payload["dry_run"] == false &&
               payload["analysis_sha"] == aggregate.fetch("analysis_sha") &&
               payload["source_pr"] == aggregate.fetch("source") &&
               payload["review_errors"] == [] && payload["attempts"] == [] && payload["actions"] == []
          raise InconsistentRecord, "refactor patrol completion payload does not match its claimed job"
        end
        DISPOSITIONS.each { |name| payload.fetch(name) }
        payload.fetch("zero_reason")
      rescue KeyError => e
        raise InconsistentRecord, "refactor patrol completion payload is missing #{e.key.inspect}"
      end

      def action_authorized_for?(aggregate, payload)
        policy = aggregate.fetch("policy")
        (policy.fetch("auto_fix") && payload.fetch("accepted").any?) ||
          (policy.fetch("issue_filing") && payload.fetch("flagged").any? { |item| item["admissible"] == true })
      end

      def source_from_manifest(manifest)
        unless manifest.is_a?(Hash) && manifest["schema"] == PrManifest::SCHEMA &&
               manifest["schema_version"] == PrManifest::SCHEMA_VERSION
          raise CorruptRecord, "refactor patrol intake requires a v2 PR manifest"
        end

        source = manifest.fetch("source")
        %w[url number repository registration base_branch base_sha merge_sha merged_at].each do |key|
          source.fetch(key)
        end
        source.merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
      end

      def queued_aggregate(job_id:, source:, policy:, now:)
        timestamp = now.utc.iso8601
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => job_id,
          "source" => source,
          "analysis_sha" => nil,
          "policy" => policy,
          "state" => "queued",
          "complete" => false,
          "dispositions" => DISPOSITIONS.to_h { |name| [ name, [] ] },
          "feature_results" => [],
          "review_errors" => [],
          "zero_reason" => nil,
          "attempts" => [],
          "actions" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
      end

      def quarantine_job_source!(job_id, authoritative:, candidate:)
        directory = File.join(root, "quarantine", "jobs")
        digest = ::Digest::SHA256.hexdigest(JSON.generate(candidate.sort.to_h))
        path = File.join(directory, "#{job_id}-#{digest}.json")
        return path if File.file?(path)

        evidence = {
          "schema" => "hive-refactor-patrol-job-intake-conflict",
          "schema_version" => 1,
          "job_id" => job_id,
          "reason" => "divergent_job_source",
          "authoritative_source" => authoritative,
          "candidate_source" => candidate
        }
        atomic_write(path, evidence)
      end

      def jobs_dir
        File.join(root, "jobs")
      end

      def job_path(job_id)
        File.join(jobs_dir, "#{validate_id!(job_id)}.json")
      end

      def validate_id!(job_id)
        id = job_id.to_s
        raise InconsistentRecord, "invalid refactor patrol job id #{id.inspect}" unless id.match?(ID_PATTERN)

        id
      end

      def read_job_path(path, expected_job_id:)
        data = JSON.parse(File.read(path))
        raise CorruptRecord.new("refactor patrol job must contain a JSON object", path: path) unless data.is_a?(Hash)

        version = data["schema_version"]
        unless version.is_a?(Integer)
          raise CorruptRecord.new("refactor patrol job has no integer schema_version", path: path)
        end
        if version != SCHEMA_VERSION
          raise UnsupportedVersion.new("unsupported refactor patrol job schema_version #{version}", path: path)
        end

        validate_job!(data, path: path)
        unless data.fetch("job_id") == expected_job_id
          raise InconsistentRecord.new(
            "refactor patrol job id #{data.fetch('job_id').inspect} does not match filename #{expected_job_id.inspect}",
            path: path
          )
        end
        data
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
        raise CorruptRecord.new("cannot read refactor patrol job (#{e.class}: #{e.message})", path: path)
      end

      def validate_job!(data, path: nil)
        strict_hash!(data, required: TOP_LEVEL_KEYS, allowed: TOP_LEVEL_KEYS, label: "job", path: path)
        inconsistent!("unexpected job schema", path) unless data.fetch("schema") == SCHEMA
        version = data.fetch("schema_version")
        unless version.is_a?(Integer)
          raise CorruptRecord.new("job schema_version must be an integer", path: path)
        end
        if version != SCHEMA_VERSION
          raise UnsupportedVersion.new("unsupported refactor patrol job schema_version #{version}", path: path)
        end
        validate_id!(data.fetch("job_id"))
        inconsistent!("job state is invalid", path) unless STATES.include?(data.fetch("state"))
        inconsistent!("job complete must be boolean", path) unless [ true, false ].include?(data.fetch("complete"))
        if data.fetch("complete") != (data.fetch("state") == "complete")
          inconsistent!("job state and complete flag disagree", path)
        end

        validate_source!(data.fetch("source"), path)
        validate_policy!(data.fetch("policy"), path)
        string_or_nil!(data.fetch("analysis_sha"), "analysis_sha", path)
        timestamp!(data.fetch("created_at"), "created_at", path)
        timestamp!(data.fetch("updated_at"), "updated_at", path)

        errors = array_of_hashes!(data.fetch("review_errors"), "review_errors", path)
        inconsistent!("complete job cannot retain review errors", path) if data.fetch("complete") && errors.any?
        zero_reason = data.fetch("zero_reason")
        unless zero_reason.nil? || ZERO_REASONS.include?(zero_reason)
          inconsistent!("zero_reason is invalid", path)
        end
        inconsistent!("partial job cannot have zero_reason", path) if !data.fetch("complete") && zero_reason

        dispositions = data.fetch("dispositions")
        strict_hash!(dispositions, required: DISPOSITIONS, allowed: DISPOSITIONS, label: "dispositions", path: path)
        seen_ids = {}
        fingerprint_by_id = {}
        DISPOSITIONS.each do |name|
          array_of_hashes!(dispositions.fetch(name), "#{name} dispositions", path).each do |item|
            validate_disposition!(item, name, path)
            id = item.fetch("id")
            inconsistent!("thesis #{id.inspect} appears in multiple dispositions", path) if seen_ids[id]
            seen_ids[id] = name
            fingerprint_by_id[id] = item.fetch("fingerprint")
          end
        end
        if data.fetch("complete") && seen_ids.empty? && zero_reason.nil?
          inconsistent!("complete zero-thesis job requires zero_reason", path)
        end

        array_of_hashes!(data.fetch("feature_results"), "feature_results", path).each do |item|
          strict_hash!(item, required: FEATURE_RESULT_KEYS, allowed: FEATURE_RESULT_KEYS,
                             label: "feature result", path: path)
          nonempty_string!(item.fetch("feature_id"), "feature result id", path)
          inconsistent!("feature result complete must be boolean", path) unless [ true, false ].include?(item.fetch("complete"))
          string_array!(item.fetch("thesis_ids"), "feature result thesis_ids", path)
          array_of_hashes!(item.fetch("errors"), "feature result errors", path)
        end
        array_of_hashes!(data.fetch("attempts"), "attempts", path)
        validate_actions!(data.fetch("actions"), data.fetch("job_id"), fingerprint_by_id, path)
        data
      rescue KeyError => e
        raise CorruptRecord.new("refactor patrol job is missing #{e.key.inspect}", path: path)
      end

      def validate_source!(source, path)
        strict_hash!(source, required: %w[url number repository registration base_branch base_sha merge_sha],
                            allowed: SOURCE_KEYS, label: "source", path: path)
        %w[url repository registration base_branch base_sha merge_sha].each do |key|
          nonempty_string!(source.fetch(key), "source #{key}", path)
        end
        inconsistent!("source number must be a positive integer", path) unless source.fetch("number").is_a?(Integer) && source.fetch("number").positive?
        string_array!(source["changed_paths"], "source changed_paths", path) if source.key?("changed_paths")
        timestamp!(source["merged_at"], "source merged_at", path) if source.key?("merged_at")
        nonempty_string!(source["manifest_checksum"], "source manifest_checksum", path) if source.key?("manifest_checksum")
      end

      def validate_policy!(policy, path)
        strict_hash!(policy, required: %w[discovery auto_fix issue_filing], allowed: POLICY_KEYS,
                             label: "policy", path: path)
        %w[discovery auto_fix issue_filing].each do |key|
          inconsistent!("policy #{key} must be boolean", path) unless [ true, false ].include?(policy.fetch(key))
        end
        timestamp!(policy["captured_at"], "policy captured_at", path) if policy.key?("captured_at")
      end

      def validate_disposition!(item, name, path)
        strict_hash!(item, required: %w[id feature_id fingerprint score admissible reasons],
                           allowed: DISPOSITION_KEYS, label: "#{name} disposition", path: path)
        %w[id feature_id fingerprint].each { |key| nonempty_string!(item.fetch(key), "disposition #{key}", path) }
        inconsistent!("disposition score must be numeric", path) unless item.fetch("score").is_a?(Numeric)
        inconsistent!("disposition admissible must be boolean", path) unless [ true, false ].include?(item.fetch("admissible"))
        reasons = string_array!(item.fetch("reasons"), "disposition reasons", path)
        if name == "accepted"
          inconsistent!("accepted disposition cannot have reasons", path) unless reasons.empty?
          inconsistent!("accepted disposition must be admissible", path) unless item.fetch("admissible")
        else
          inconsistent!("#{name} disposition requires reasons", path) if reasons.empty?
        end
        nonempty_string!(item["reference"], "disposition reference", path) if item.key?("reference")
      end

      def validate_actions!(actions, job_id, fingerprint_by_id, path)
        seen = {}
        array_of_hashes!(actions, "actions", path).each do |action|
          strict_hash!(action, required: ACTION_KEYS, allowed: ACTION_KEYS, label: "action", path: path)
          %w[canonical_action_id thesis_id thesis_fingerprint kind owner_job_id outcome].each do |key|
            nonempty_string!(action.fetch(key), "action #{key}", path)
          end
          inconsistent!("action terminal must be boolean", path) unless [ true, false ].include?(action.fetch("terminal"))
          inconsistent!("action receipts must be an object", path) unless action.fetch("receipts").is_a?(Hash)
          id = action.fetch("canonical_action_id")
          inconsistent!("duplicate canonical action #{id.inspect}", path) if seen[id]
          seen[id] = true
          expected_fingerprint = fingerprint_by_id[action.fetch("thesis_id")]
          unless expected_fingerprint == action.fetch("thesis_fingerprint")
            inconsistent!("action thesis identity is not present in this job", path)
          end
          if action.fetch("owner_job_id") != job_id && !action.fetch("receipts").empty?
            inconsistent!("linked canonical action #{id.inspect} cannot duplicate owner receipts", path)
          end
        end
      end

      def validate_transition!(existing, replacement, path)
        %w[source policy created_at].each do |key|
          next if existing.fetch(key) == replacement.fetch(key)

          inconsistent!("job #{key} is immutable", path)
        end
        if !existing.fetch("analysis_sha").to_s.empty? &&
           existing.fetch("analysis_sha") != replacement.fetch("analysis_sha")
          inconsistent!("job analysis_sha is immutable once pinned", path)
        end

        old_dispositions = disposition_by_id(existing.fetch("dispositions"))
        new_dispositions = disposition_by_id(replacement.fetch("dispositions"))
        old_dispositions.each do |id, old_value|
          unless new_dispositions[id] == old_value
            inconsistent!("analysis disposition for thesis #{id.inspect} is immutable", path)
          end
        end
        if existing.fetch("complete") && existing != replacement
          inconsistent!("complete job aggregate is write-once", path)
        end
      end

      def disposition_by_id(dispositions)
        DISPOSITIONS.each_with_object({}) do |name, indexed|
          dispositions.fetch(name).each do |item|
            indexed[item.fetch("id")] = [ name, item ]
          end
        end
      end

      def strict_hash!(value, required:, allowed:, label:, path:)
        raise CorruptRecord.new("#{label} must be an object", path: path) unless value.is_a?(Hash)

        missing = required - value.keys
        unknown = value.keys - allowed
        raise CorruptRecord.new("#{label} is missing keys #{missing.inspect}", path: path) unless missing.empty?
        inconsistent!("#{label} has unknown keys #{unknown.inspect}", path) unless unknown.empty?
        value
      end

      def array_of_hashes!(value, label, path)
        raise CorruptRecord.new("#{label} must be an array of objects", path: path) unless value.is_a?(Array) && value.all? { |item| item.is_a?(Hash) }

        value
      end

      def string_array!(value, label, path)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise CorruptRecord.new("#{label} must be an array of non-empty strings", path: path)
        end
        value
      end

      def nonempty_string!(value, label, path)
        inconsistent!("#{label} must be a non-empty string", path) unless value.is_a?(String) && !value.empty?
      end

      def string_or_nil!(value, label, path)
        inconsistent!("#{label} must be a string or null", path) unless value.nil? || value.is_a?(String)
      end

      def timestamp!(value, label, path)
        nonempty_string!(value, label, path)
        Time.iso8601(value)
      rescue ArgumentError
        inconsistent!("#{label} must be an ISO-8601 timestamp", path)
      end

      def inconsistent!(message, path)
        raise InconsistentRecord.new(message, path: path)
      end

      def read_derived_index(path, schema:, collection:)
        return yield unless File.file?(path)

        data = JSON.parse(File.read(path))
        unless data.is_a?(Hash) && data["schema"] == schema && data["schema_version"] == SCHEMA_VERSION &&
               data[collection].is_a?(Hash) && (data.keys - %w[schema schema_version] - [ collection ]).empty?
          return yield
        end
        data
      rescue JSON::ParserError, SystemCallError, IOError
        yield
      end

      def atomic_write(path, data)
        dir = File.dirname(path)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(data)}\n", mode: 0o600)
        fsync_directory(dir)
        path
      end

      def fsync_directory(dir)
        File.open(dir, File::RDONLY) { |handle| handle.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
        nil
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => e
        raise CorruptRecord, "refactor patrol job is not JSON serializable (#{e.message})"
      end
    end
  end
end
