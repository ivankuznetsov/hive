#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json"
require "open3"
require "time"
require "hive/git_ref"
require "hive/git_ops"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_adapter"
require "hive/patrol/state_store"
require "hive/patrol_fix/admission_store"
require "hive/refactor_patrol/fix_admission_adapter"
require "hive/refactor_patrol/job_store"
require "hive/secret_patterns"

module Hive
  module Scripts
    class MigratePatrolFindings
      DEFAULT_ACCEPTED_AT = Time.at(0).utc
      REDACTABLE_FINDING_FIELDS = %w[
        title description recommendation scope contract impact root_cause
        reproduction validation evidence
      ].freeze

      def initialize(project_root, dry_run: false, out: $stdout)
        @project_root = File.expand_path(project_root)
        @hive_state = File.join(@project_root, ".hive-state")
        @dry_run = dry_run
        @out = out
        @git_ops = Hive::GitOps.new(@project_root)
      end

      def call
        validate_project!
        findings = active_findings
        ensure_unique_finding_ids!(findings)
        ordinary_entries = findings.map { |finding| ordinary_admission_entry(finding) }
        architecture_entries = architecture_admission_entries
        existing_ordinary = existing_admissions(ordinary_entries, source: "ordinary Patrol")
        existing_architecture = existing_admissions(
          architecture_entries, source: "Architecture Patrol"
        )

        ordinary = migrate_admissions(ordinary_entries, existing_ordinary)
        architecture = migrate_admissions(architecture_entries, existing_architecture)
        @out.puts summary("ordinary", ordinary)
        @out.puts summary("architecture", architecture)
        { ordinary: ordinary, architecture: architecture }
      end

      private

      def migrate_admissions(entries, existing)
        created = 0
        present = 0
        entries.each do |entry|
          if existing.key?(entry.fetch(:occurrence_id))
            present += 1
            next
          end

          if @dry_run
            @out.puts "would migrate #{entry.fetch(:description)}"
          else
            admission_store.reserve!(
              occurrence_id: entry.fetch(:occurrence_id),
              snapshot: entry.fetch(:snapshot),
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

      def ensure_unique_finding_ids!(findings)
        duplicate = findings.map { |finding| finding.id.to_s }
          .tally.find { |_id, count| count > 1 }&.first
        return unless duplicate

        raise Hive::ConfigError, "duplicate Patrol finding id #{duplicate}"
      end

      def ordinary_admission_entry(finding)
        candidate = migration_finding(finding)
        reservation = ordinary_admission_adapter.reservation_for(
          candidate, accepted_at: DEFAULT_ACCEPTED_AT
        )
        admission_entry(reservation, description: "ordinary #{finding.id}")
      end

      def migration_finding(finding)
        data = finding.to_h
        REDACTABLE_FINDING_FIELDS.each do |key|
          data[key] = redact_finding_value(data[key]) if data.key?(key)
        end
        data["target_sha"] = legacy_target_revision if data["target_sha"].to_s.empty?
        unless %w[admitted recurrence_after_terminal].include?(data["lifecycle_reason"].to_s)
          data["lifecycle_reason"] = "admitted"
        end
        Hive::Patrol::Finding.from_h(data)
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

      def architecture_admission_entries
        records = architecture_jobs.flat_map do |job|
          %w[fix discuss].flat_map do |route|
            job.dig("dispositions", route).filter_map do |disposition|
              reservation = architecture_admission_adapter.reservation_for(
                job, disposition, accepted_at: DEFAULT_ACCEPTED_AT
              )
              next unless reservation

              admission_entry(
                reservation,
                description: "architecture #{job.fetch('job_id')}:#{disposition.fetch('id')}"
              )
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

      def ordinary_admission_adapter
        @ordinary_admission_adapter ||= Hive::Patrol::FixAdmissionAdapter.for_project(
          project_root: @project_root, hive_state_path: @hive_state
        )
      end

      def architecture_admission_adapter
        @architecture_admission_adapter ||=
          Hive::RefactorPatrol::FixAdmissionAdapter.for_project(
            project_root: @project_root, hive_state_path: @hive_state
          )
      end

      def admission_entry(reservation, description:)
        snapshot = reservation.fetch(:snapshot)
        {
          occurrence_id: reservation.fetch(:occurrence_id),
          description: description,
          snapshot: snapshot,
          source: snapshot.to_h,
          source_digest: snapshot.digest
        }
      end

      def admission_store
        @admission_store ||= ordinary_admission_adapter.store
      end

      def existing_admissions(entries, source:)
        entries.each_with_object({}) do |entry, existing|
          id = entry.fetch(:occurrence_id)
          record = admission_store.fetch(id)
          next unless record
          unless record.fetch("source_digest") == entry.fetch(:source_digest) &&
                 record.fetch("source") == entry.fetch(:source)
            raise Hive::ConfigError,
                  "existing admission has different data for #{source} occurrence #{id}"
          end
          existing[id] = record
        end
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
