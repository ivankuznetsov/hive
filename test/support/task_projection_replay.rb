require "digest"
require "fileutils"
require "json"
require "tmpdir"
require "hive"
require "hive/conditions/gate_evaluator"
require "hive/conditions/policy"
require "hive/markers"
require "hive/task_projection/store"

module HiveTestSupport
  class TaskProjectionReplay
    SCHEMA_VERSION = 1

    class InvalidFixture < StandardError; end

    Result = Data.define(:projection, :canonical, :expected, :manifest)

    attr_reader :bundle_path, :manifest

    def initialize(bundle_path)
      @bundle_path = File.expand_path(bundle_path)
      @manifest = JSON.parse(File.read(File.join(@bundle_path, "manifest.json")))
      validate!
    end

    def replay(snapshot: :missing, shuffle: false)
      Dir.mktmpdir("task-projection-replay") do |dir|
        task_folder = File.join(dir, manifest.fetch("incident"))
        FileUtils.cp_r(bundle_path, task_folder)
        prepare_snapshot(task_folder, snapshot)
        shuffle_journal(task_folder) if shuffle
        verify_files!(task_folder)

        marker = Hive::Markers.current(File.join(task_folder, manifest.fetch("state_file")))
        projection = projection_store(task_folder).read(marker: marker)
        canonical = canonical_projection(projection)
        expected = JSON.parse(File.read(File.join(task_folder, manifest.fetch("expected_projection"))))
        unless Hive::TaskProjection.canonical_json(canonical) == Hive::TaskProjection.canonical_json(expected)
          raise InvalidFixture, "replayed projection does not match expected projection"
        end

        return Result.new(
          projection: projection, canonical: canonical,
          expected: expected, manifest: manifest
        )
      end
    end

    def validate!
      unless manifest["schema_version"] == SCHEMA_VERSION
        raise InvalidFixture, "fixture schema_version must be #{SCHEMA_VERSION}"
      end
      %w[
        incident source sanitization state_file journal expected_projection files
        synthetic_events provenance
      ].each do |key|
        raise InvalidFixture, "fixture missing #{key}" unless manifest.key?(key)
      end
      verify_files!(bundle_path)
      validate_synthetic_provenance!
      validate_attempt_metadata!
      true
    end

    private

    def verify_files!(root)
      manifest.fetch("files").each do |relative, expected_digest|
        path = File.join(root, relative)
        raise InvalidFixture, "fixture file missing: #{relative}" unless File.file?(path)

        actual = ::Digest::SHA256.file(path).hexdigest
        unless actual == expected_digest
          raise InvalidFixture, "fixture digest mismatch for #{relative}: #{actual}"
        end
      end
    end

    def validate_synthetic_provenance!
      records = journal_records(bundle_path)
      declared = manifest.fetch("synthetic_events").sort
      actual = records.filter_map do |record|
        record["event_id"] if record.dig("provenance", "synthetic") == true
      end.sort
      raise InvalidFixture, "synthetic event declaration mismatch" unless actual == declared

      declared.each do |event_id|
        record = records.find { |candidate| candidate["event_id"] == event_id }
        source = record&.dig("provenance", "source").to_s
        raise InvalidFixture, "synthetic event #{event_id} lacks provenance source" if source.empty?
      end
    end

    def validate_attempt_metadata!
      relative = manifest["attempts_file"]
      return unless relative

      data = JSON.parse(File.read(File.join(bundle_path, relative)))
      attempts = Array(data["attempts"])
      ids = attempts.map { |attempt| attempt.fetch("attempt_id") }
      raise InvalidFixture, "duplicate attempt metadata" unless ids.uniq == ids

      unknown = journal_records(bundle_path).filter_map do |record|
        next unless record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
        next if record["attempt_id"] == Hive::TaskJournal::LEGACY_ATTEMPT_ID

        record["attempt_id"] unless ids.include?(record["attempt_id"])
      end.uniq
      raise InvalidFixture, "journal references unknown attempts: #{unknown.join(', ')}" unless unknown.empty?
    end

    def journal_records(root)
      Hive::TaskProjection.read_journal(File.join(root, manifest.fetch("journal")))
    end

    def prepare_snapshot(task_folder, mode)
      store = projection_store(task_folder)
      case mode.to_sym
      when :missing
        nil
      when :corrupt
        File.write(store.snapshot_path, "{corrupt")
      when :stale
        journal_path = store.journal_path
        full = File.binread(journal_path)
        lines = full.lines
        File.binwrite(journal_path, lines.first([ lines.size / 2, 1 ].max).join)
        store.rebuild!
        File.binwrite(journal_path, full)
      else
        raise ArgumentError, "unknown snapshot replay mode #{mode.inspect}"
      end
    end

    def shuffle_journal(task_folder)
      path = File.join(task_folder, manifest.fetch("journal"))
      lines = File.readlines(path)
      File.write(path, lines.reverse.join)
    end

    def projection_store(task_folder)
      Hive::TaskProjection::Store.new(
        task_folder: task_folder, attempt_store: fixture_attempt_store(task_folder)
      )
    end

    def fixture_attempt_store(task_folder)
      metadata = JSON.parse(File.read(File.join(task_folder, manifest.fetch("attempts_file"))))
      attempts = metadata.fetch("attempts").to_h do |attributes|
        attempt = attributes.dup
        attempt.define_singleton_method(:attempt_id) { fetch("attempt_id") }
        attempt.define_singleton_method(:task_input_epoch) { fetch("task_input_epoch") }
        attempt.define_singleton_method(:ownership_generation) { fetch("ownership_generation") }
        [ attempt.fetch("attempt_id"), attempt ]
      end
      Object.new.tap do |store|
        store.define_singleton_method(:fetch) { |attempt_id| attempts[attempt_id] }
      end
    end

    def canonical_projection(projection)
      current = projection["conditions"].fetch("current").to_h do |fact|
        [
          fact.fetch("condition"),
          fact.slice("state", "reason", "attempt_id", "task_generation", "commit_generation", "event_id")
        ]
      end
      history = projection["conditions"].fetch("history").map do |fact|
        fact.slice(
          "event_id", "condition", "state", "original_state", "attempt_id",
          "task_generation", "commit_generation", "superseded_reason", "superseded_by_event_id"
        )
      end
      rule = Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
      gate = Hive::Conditions::GateEvaluator.new(projection: projection, rule: rule).evaluate
      Hive::TaskProjection.canonical(
        "identity" => projection["identity"],
        "current_conditions" => current,
        "history" => history,
        "gate" => gate.to_h
      )
    end
  end
end
