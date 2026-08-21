#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "digest"
require "json"
require "time"
require "hive/patrol/finding"
require "hive/patrol/state_store"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/task_manifest"
require "hive/task_capture"
require "hive/task_meta"
require "hive/workflows"

module Hive
  module Scripts
    class MigratePatrolFindings
      MAX_TEXT_BYTES = 16 * 1024
      MAX_SHORT_TEXT_BYTES = 512
      PATH_BYTES = 1_024
      DEFAULT_ACCEPTED_AT = Time.at(0).utc

      def initialize(project_root, dry_run: false, out: $stdout)
        @project_root = File.expand_path(project_root)
        @hive_state = File.join(@project_root, ".hive-state")
        @dry_run = dry_run
        @out = out
      end

      def call
        validate_project!
        entries = active_findings.map { |finding| entry_for(finding) }
        existing = existing_tasks
        ensure_no_conflicts!(entries, existing)

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

        @out.puts "#{@dry_run ? 'would migrate' : 'migrated'} #{created}, already present #{present}"
        { created: created, present: present, total: entries.length }
      end

      private

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
        Hive::PatrolFix::SourceSnapshot.build(
          engine: "ordinary_patrol",
          identity: data.fetch("id").to_s,
          title: text(data["title"], fallback: "Patrol finding #{data.fetch('id')}", max: 2_048),
          summary: text(data["description"] || data["root_cause"],
                        fallback: "Accepted Patrol finding", max: MAX_TEXT_BYTES),
          target_revision: data.fetch("target_sha").to_s,
          evidence: evidence(data),
          affected_code: affected_code(data),
          reproduction_guidance: text(
            data["reproduction"] || data["validation"] || data["recommendation"],
            fallback: "Reproduce and validate the accepted Patrol finding.", max: MAX_TEXT_BYTES
          ),
          discovery_run: text(data["validation_key"] || data["fingerprint"],
                              fallback: data.fetch("id").to_s, max: MAX_SHORT_TEXT_BYTES),
          semantic_lineage: semantic_lineage(data),
          aliases: [], external_issues: [], existing_pull_requests: [],
          accepted_at: accepted_at(data).iso8601
        )
      end

      def evidence(data)
        values = Array(data["evidence"]).map { |value| bounded_json_text(value) }.reject(&:empty?)
        values << text(data["root_cause"] || data["description"],
                       fallback: "Accepted Patrol evidence", max: MAX_TEXT_BYTES) if values.empty?
        values.first(Hive::PatrolFix::SourceSnapshot::MAX_EVIDENCE)
      end

      def affected_code(data)
        scope = data["scope"].is_a?(Hash) ? data.fetch("scope") : {}
        candidates = Array(scope["paths"]) + Array(scope["files"]) +
                     Array(data["evidence"]).filter_map do |item|
                       item.is_a?(Hash) && (item["path"] || item["file"] || item[:path] || item[:file])
                     end
        paths = candidates.map(&:to_s).select { |path| safe_path?(path) }.uniq
        (paths.empty? ? [ "unknown" ] : paths).first(Hive::PatrolFix::SourceSnapshot::MAX_PATHS)
      end

      def semantic_lineage(data)
        values = [ data["fingerprint"], data["feature_id"], data["root_cause"] ]
          .compact.map { |value| text(value, fallback: nil, max: MAX_SHORT_TEXT_BYTES) }.compact.uniq
        (values.empty? ? [ data.fetch("id").to_s ] : values).first(Hive::PatrolFix::SourceSnapshot::MAX_LINEAGE)
      end

      def accepted_at(data)
        value = data["lifecycle_updated_at"].to_s
        value.empty? ? DEFAULT_ACCEPTED_AT : Time.iso8601(value).utc
      rescue ArgumentError
        DEFAULT_ACCEPTED_AT
      end

      def slug_for(finding)
        stem = finding.title.to_s.unicode_normalize(:nfd).downcase
          .gsub(/[^a-z0-9]+/, " ").strip.split.first(6).join("-")
        stem = "finding" if stem.empty?
        digest = Digest::SHA256.hexdigest(finding.id.to_s)[0, 10]
        "patrol-#{stem[0, 44].sub(/-+\z/, '')}-#{digest}"
      end

      def existing_tasks
        Dir.glob(File.join(@hive_state, "stages", "*", "*", Hive::TaskMeta::FILENAME)).each_with_object({}) do |path, result|
          read = Hive::TaskMeta.read_for_admission(File.dirname(path))
          raise Hive::ConfigError, "cannot inspect task metadata at #{path}: #{read.error || read.status}" unless read.status == :ok

          key = read.data[:idempotency_key]
          next unless key
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

      def capture(entry)
        Hive::TaskCapture.new(
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

      def bounded_json_text(value)
        raw = value.is_a?(String) ? value : JSON.generate(value)
        text(raw, fallback: "", max: MAX_TEXT_BYTES)
      rescue JSON::GeneratorError, TypeError
        ""
      end

      def text(value, fallback:, max:)
        result = value.to_s.strip
        result = fallback.to_s if result.empty? && fallback
        return nil if result.empty?

        result.byteslice(0, max).to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          .gsub(/[\u0000-\u001f\u007f]/, " ").strip
      end

      def safe_path?(path)
        !path.empty? && !path.start_with?("/") && !path.include?("\\") &&
          !path.split("/").include?("..") && path.bytesize <= PATH_BYTES
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
