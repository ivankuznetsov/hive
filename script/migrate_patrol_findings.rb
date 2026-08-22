#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "digest"
require "json"
require "open3"
require "tmpdir"
require "time"
require "hive/git_ref"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_adapter"
require "hive/patrol/state_store"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/task_manifest"
require "hive/refactor_patrol/fix_admission_adapter"
require "hive/refactor_patrol/job_store"
require "hive/secret_patterns"
require "hive/task_capture"
require "hive/task_meta"
require "hive/workflows"

module Hive
  module Scripts
    class MigratePatrolFindings
      DEFAULT_ACCEPTED_AT = Time.at(0).utc
      REDACTABLE_FINDING_FIELDS = %w[
        title description recommendation scope contract impact root_cause
        reproduction validation evidence
      ].freeze

      class PatrolTaskCapture < Hive::TaskCapture
        private

        def idempotency_metadata_paths
          super.select { |path| File.binread(path).include?(idempotency_key) }
        end
      end

      def initialize(project_root, dry_run: false, out: $stdout)
        @project_root = File.expand_path(project_root)
        @hive_state = File.join(@project_root, ".hive-state")
        @dry_run = dry_run
        @out = out
        @git_ops = Hive::GitOps.new(@project_root)
      end

      def call
        validate_project!
        ordinary_entries = active_findings.map { |finding| entry_for(finding) }
        architecture_entries = architecture_admission_entries
        candidate_keys = ordinary_entries.to_h { |entry| [ entry.fetch(:idempotency_key), true ] }
        existing = existing_tasks(candidate_keys)
        ensure_no_conflicts!(ordinary_entries, existing)
        existing_admissions = existing_architecture_admissions(architecture_entries)

        ordinary = migrate_ordinary(ordinary_entries, existing)
        architecture = migrate_architecture(architecture_entries, existing_admissions)
        @out.puts summary("ordinary", ordinary)
        @out.puts summary("architecture", architecture)
        { ordinary: ordinary, architecture: architecture }
      end

      private

      def migrate_ordinary(entries, existing)
        created = 0
        present = 0
        entries.each do |entry|
          if existing.key?(entry.fetch(:idempotency_key))
            present += 1
            next
          end

          if @dry_run
            @out.puts "would migrate #{entry.fetch(:finding_id)} -> #{entry.fetch(:slug)}"
          else
            capture(entry).call
          end
          created += 1
        end
        { created: created, present: present, total: entries.length }
      end

      def migrate_architecture(entries, existing)
        created = 0
        present = 0
        store = architecture_admission_store
        entries.each do |entry|
          if existing.key?(entry.fetch(:occurrence_id))
            present += 1
            next
          end

          if @dry_run
            @out.puts "would migrate architecture #{entry.fetch(:job_id)}:#{entry.fetch(:disposition_id)}"
          else
            store.reserve!(
              occurrence_id: entry.fetch(:occurrence_id),
              snapshot: Hive::PatrolFix::SourceSnapshot.new(entry.fetch(:source)),
              now: DEFAULT_ACCEPTED_AT
            )
          end
          created += 1
        end
        { created: created, present: present, total: entries.length }
      end

      def summary(source, result)
        action = @dry_run ? "would migrate" : "migrated"
        "#{source}: #{action} #{result.fetch(:created)}, already present #{result.fetch(:present)}"
      end

      def validate_project!
        raise Hive::ConfigError, "not a Hive project: #{@hive_state}" unless File.directory?(@hive_state)
      end

      def active_findings
        Hive::Patrol::StateStore.new(
          @project_root, hive_state_path: @hive_state
        ).findings.select { |finding| finding.lifecycle_state.to_s == "active" }
      end

      def entry_for(finding)
        snapshot = source_snapshot(finding)
        manifest = {
          "schema" => Hive::PatrolFix::TaskManifest::SCHEMA,
          "schema_version" => Hive::PatrolFix::TaskManifest::SCHEMA_VERSION,
          "task" => { "slug" => slug_for(finding), "generation" => 1 },
          "evidence_revision" => { "generation" => 1, "digest" => snapshot.evidence_digest },
          "target_revision" => snapshot.to_h.fetch("target_revision"),
          "sources" => [ snapshot.source_manifest_entry ],
          "aliases" => [ { "kind" => "ordinary_finding", "value" => finding.id.to_s } ],
          "relations" => { "successor" => nil, "issues" => [] }
        }
        state_bytes = Hive::PatrolFix.canonical_json(manifest)
        {
          finding_id: finding.id.to_s,
          slug: manifest.dig("task", "slug"),
          state_bytes: state_bytes,
          idempotency_key: "patrol-fix:legacy-finding:#{finding.id}",
          input_fingerprint: Digest::SHA256.hexdigest(state_bytes)
        }
      end

      def source_snapshot(finding)
        data = finding.to_h
        REDACTABLE_FINDING_FIELDS.each do |key|
          data[key] = redact_finding_value(data[key]) if data.key?(key)
        end
        data["target_sha"] = legacy_target_revision if data["target_sha"].to_s.empty?
        Hive::Patrol::FixAdmissionAdapter.snapshot_for(
          Hive::Patrol::Finding.from_h(data), accepted_at: DEFAULT_ACCEPTED_AT
        )
      end

      def redact_finding_value(value)
        case value
        when String
          Hive::SecretPatterns.redact(value)
        when Array
          value.map { |item| redact_finding_value(item) }
        when Hash
          value.to_h { |key, item| [ key, redact_finding_value(item) ] }
        else
          value
        end
      end

      def legacy_target_revision
        @legacy_target_revision ||= begin
          branch = Hive::GitRef.validate_branch_name(@git_ops.default_branch)
          remote_ref = "refs/remotes/origin/#{branch}^{commit}"
          out, _err, status = Open3.capture3(
            "git", "-C", @project_root, "rev-parse", "--verify", remote_ref
          )
          revision = status.success? ? out.strip : @git_ops.head_sha
          unless revision.match?(/\A[0-9a-f]{40}\z/i)
            raise Hive::ConfigError, "cannot resolve a target revision for legacy Patrol findings"
          end
          revision.downcase
        end
      end

      def slug_for(finding)
        stem = finding.title.to_s.unicode_normalize(:nfd).downcase
          .gsub(/[^a-z0-9]+/, " ").strip.split.first(6).join("-")
        stem = "finding" if stem.empty?
        digest = Digest::SHA256.hexdigest(finding.id.to_s)[0, 10]
        "patrol-#{stem[0, 44].sub(/-+\z/, '')}-#{digest}"
      end

      def existing_tasks(candidate_keys)
        Dir.glob(File.join(@hive_state, "stages", "*", "*", Hive::TaskMeta::FILENAME)).each_with_object({}) do |path, result|
          read = Hive::TaskMeta.read_for_admission(File.dirname(path))
          unless read.status == :ok
            bytes = File.binread(path)
            next unless candidate_keys.any? { |key, _present| bytes.include?(key) }

            raise Hive::ConfigError,
                  "cannot inspect candidate Patrol finding metadata at #{path}: " \
                    "#{read.error || read.status}"
          end

          key = read.data[:idempotency_key]
          next unless candidate_keys.key?(key)
          raise Hive::ConfigError, "duplicate task idempotency key #{key.inspect}" if result.key?(key)

          result[key] = read.data
        end
      end

      def ensure_no_conflicts!(entries, existing)
        entries.group_by { |entry| entry.fetch(:idempotency_key) }.each_value do |duplicates|
          raise Hive::ConfigError, "duplicate Patrol finding id #{duplicates.first.fetch(:finding_id)}" if duplicates.length > 1
        end
        entries.each do |entry|
          metadata = existing[entry.fetch(:idempotency_key)]
          next unless metadata
          next if metadata[:input_fingerprint] == entry.fetch(:input_fingerprint)

          raise Hive::ConfigError,
                "existing task has different data for Patrol finding #{entry.fetch(:finding_id)}"
        end
      end

      def architecture_admission_entries
        records = Dir.mktmpdir("hive-patrol-import") do |directory|
          adapter = Hive::RefactorPatrol::FixAdmissionAdapter.new(
            root: File.join(directory, "admissions")
          )
          architecture_jobs.flat_map do |job|
            %w[fix discuss].flat_map do |route|
              job.dig("dispositions", route).filter_map do |disposition|
                record = adapter.publish_disposition!(
                  job, disposition, accepted_at: DEFAULT_ACCEPTED_AT
                )
                next unless record

                {
                  occurrence_id: record.fetch("occurrence_id"),
                  job_id: job.fetch("job_id"),
                  disposition_id: disposition.fetch("id"),
                  source: record.fetch("source"),
                  source_digest: record.fetch("source_digest")
                }
              end
            end
          end
        end
        records.each_with_object({}) do |entry, unique|
          id = entry.fetch(:occurrence_id)
          prior = unique[id]
          if prior && prior.fetch(:source_digest) != entry.fetch(:source_digest)
            raise Hive::ConfigError, "duplicate Architecture Patrol occurrence #{id.inspect}"
          end
          unique[id] ||= entry
        end.values
      end

      def architecture_jobs
        Hive::RefactorPatrol::JobStore.new(
          @project_root, hive_state_path: @hive_state
        ).jobs
      end

      def architecture_admission_store
        @architecture_admission_store ||= Hive::PatrolFix::AdmissionStore.new(
          root: File.join(@hive_state, "patrol-fix", "admissions")
        )
      end

      def existing_architecture_admissions(entries)
        entries.each_with_object({}) do |entry, existing|
          id = entry.fetch(:occurrence_id)
          record = architecture_admission_store.fetch(id)
          next unless record
          unless record.fetch("source_digest") == entry.fetch(:source_digest) &&
                 record.fetch("source") == entry.fetch(:source)
            raise Hive::ConfigError,
                  "existing admission has different data for Architecture Patrol occurrence #{id}"
          end
          existing[id] = record
        end
      end

      def capture(entry)
        PatrolTaskCapture.new(
          project_root: @project_root,
          hive_state: @hive_state,
          workflow_info: {
            descriptor: Hive::Workflows::Registry.fetch(Hive::PatrolFix::WORKFLOW_ID),
            pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
          },
          slug: entry.fetch(:slug),
          state_bytes: entry.fetch(:state_bytes),
          idempotency_key: entry.fetch(:idempotency_key),
          input_fingerprint: entry.fetch(:input_fingerprint),
          git_ops: Hive::GitOps.new(@project_root)
        )
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  dry_run = args.delete("--dry-run")
  if args.length > 1
    warn "usage: #{File.basename($PROGRAM_NAME)} [PROJECT_ROOT] [--dry-run]"
    exit 64
  end

  begin
    Hive::Scripts::MigratePatrolFindings.new(args.fetch(0, Dir.pwd), dry_run: !dry_run.nil?).call
  rescue Hive::Error, ArgumentError, KeyError, JSON::ParserError => error
    warn "hive: #{error.message}"
    exit 1
  end
end
