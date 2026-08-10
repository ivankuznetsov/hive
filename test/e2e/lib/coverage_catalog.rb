require "digest"
require "psych"
require_relative "paths"
require_relative "scenario_parser"
require_relative "schemas"

module Hive
  module E2E
    class CoverageCatalog
      class InvalidCatalog < StandardError; end
      class UnknownCoverage < StandardError; end

      Entry = Data.define(
        :id, :title, :description, :maturity, :profiles,
        :constraints, :docs, :code
      )

      DEFAULT_PATH = File.join(Paths.e2e_root, "coverage.yml")
      ID_PATTERN = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
      PROFILE_PATTERN = /\A[a-z][a-z0-9_-]*\z/
      MATURITIES = %w[required advisory planned].freeze
      CONSTRAINT_KEYS = %w[platforms providers].freeze

      attr_reader :entries, :scenarios, :digest

      def self.load(scenarios: nil, path: DEFAULT_PATH, repo_root: Paths.repo_root)
        scenarios ||= scenario_files.map { |scenario_path| ScenarioParser.parse(scenario_path) }
        new(path: path, scenarios: scenarios, repo_root: repo_root).tap(&:validate!)
      end

      def self.scenario_files(scenarios_dir: Paths.scenarios_dir)
        Dir[File.join(scenarios_dir, "*.yml")]
          .reject { |path| File.basename(path).start_with?("_") }
          .sort
      end

      def initialize(path:, scenarios:, repo_root:)
        @path = path
        @repo_root = File.realpath(repo_root)
        @scenarios = scenarios.freeze
        @raw = load_yaml
        @digest = Digest::SHA256.file(@path).hexdigest
        @profiles = parse_profiles
        @entries = parse_entries.freeze
        @entries_by_id = @entries.to_h { |entry| [ entry.id, entry ] }.freeze
        @primary_by_id = {}.freeze
        @supporting_by_id = @entries_by_id.to_h { |id, _entry| [ id, [].freeze ] }.freeze
      end

      def validate!
        validate_scenarios!
        self
      end

      def primary_scenarios
        @primary_by_id.values.sort_by(&:name)
      end

      def search(query, profile: nil)
        needle = query.to_s.strip.downcase
        raise ArgumentError, "coverage match query must be non-empty" if needle.empty?

        validate_profile!(profile) if profile
        candidates = @entries.select { |entry| profile.nil? || entry.profiles.include?(profile) }
        exact = candidates.find { |entry| entry.id == needle }
        matches = exact ? [ exact ] : candidates.select { |entry| searchable_text(entry).include?(needle) }
        matches.sort_by(&:id).map { |entry| discovery_match(entry) }
      end

      def discovery_payload(query:, profile: nil, matches:)
        {
          "schema" => "hive-e2e-coverage",
          "schema_version" => Schemas.version_for("hive-e2e-coverage"),
          "catalog_digest" => digest,
          "query" => query,
          "profile" => profile,
          "matches" => matches
        }
      end

      def select_coverage(id)
        entry = @entries_by_id[id.to_s]
        raise UnknownCoverage, "unknown coverage ID #{id.inspect}" unless entry

        match = discovery_match(entry)
        primary = runnable_primary(entry)
        selection_payload(
          profile: nil,
          coverage_ids: primary ? [ entry.id ] : [],
          scenarios: primary ? [ primary.name ] : [],
          pending: match.fetch("primary_scenario")&.fetch("pending") ? [ entry.id ] : [],
          advisory: entry.maturity == "advisory" ? [ entry.id ] : [],
          planned: entry.maturity == "planned" ? [ entry.id ] : [],
          replay_command: primary ? "bin/hive-e2e run --coverage #{entry.id}" : nil
        )
      end

      def select_profile(profile)
        validate_profile!(profile)
        members = @entries.select { |entry| entry.profiles.include?(profile) }.sort_by(&:id)
        required = members.select { |entry| entry.maturity == "required" }
        gaps = required.reject { |entry| runnable_primary(entry) }
        unless gaps.empty?
          invalid!(
            "profile #{profile.inspect} has required coverage with no active primary: " \
            "#{gaps.map(&:id).join(', ')}"
          )
        end

        selected = required.map { |entry| [ entry, runnable_primary(entry) ] }
        selection_payload(
          profile: profile,
          coverage_ids: selected.map { |entry, _scenario| entry.id },
          scenarios: selected.map { |_entry, scenario| scenario.name },
          pending: members.select { |entry| @primary_by_id[entry.id]&.pending }.map(&:id),
          advisory: members.select { |entry| entry.maturity == "advisory" }.map(&:id),
          planned: members.select { |entry| entry.maturity == "planned" }.map(&:id),
          replay_command: "bin/hive-e2e run --profile #{profile}"
        )
      end

      def scenarios_for(selection)
        names = selection.fetch("scenarios")
        by_name = @scenarios.to_h { |scenario| [ scenario.name, scenario ] }
        names.map { |name| by_name.fetch(name) }
      end

      private

      def load_yaml
        data = Psych.safe_load(File.read(@path), aliases: false) || {}
        invalid!("catalog root must be a map") unless data.is_a?(Hash)
        invalid!("schema_version must be 1") unless data["schema_version"] == 1

        data
      rescue Errno::ENOENT => e
        invalid!(e.message)
      rescue Psych::Exception => e
        invalid!(e.message)
      end

      def parse_profiles
        raw = @raw["profiles"]
        invalid!("profiles must be a non-empty map") unless raw.is_a?(Hash) && !raw.empty?

        raw.each_with_object({}) do |(name, config), profiles|
          invalid!("invalid profile #{name.inspect}") unless PROFILE_PATTERN.match?(name.to_s)
          invalid!("profile #{name.inspect} must be a map") unless config.is_a?(Hash)
          description = config["description"]
          invalid!("profile #{name.inspect} description must be non-empty") unless nonempty_string?(description)
          profiles[name.to_s] = { "description" => description }.freeze
        end.freeze
      end

      def parse_entries
        raw_entries = @raw["coverage"]
        invalid!("coverage must be a non-empty array") unless raw_entries.is_a?(Array) && !raw_entries.empty?

        entries = raw_entries.map.with_index(1) { |raw, index| parse_entry(raw, index) }
        duplicate = entries.group_by(&:id).find { |_id, matches| matches.size > 1 }
        invalid!("duplicate coverage ID #{duplicate.first.inspect}") if duplicate
        entries.sort_by(&:id)
      end

      def parse_entry(raw, index)
        invalid!("coverage entry #{index} must be a map") unless raw.is_a?(Hash)
        id = raw["id"].to_s
        invalid!("invalid coverage ID #{id.inspect}") unless ID_PATTERN.match?(id)
        %w[title description].each do |field|
          invalid!("#{id} #{field} must be non-empty") unless nonempty_string?(raw[field])
        end
        maturity = raw["maturity"].to_s
        invalid!("#{id} maturity must be one of #{MATURITIES.join(', ')}") unless MATURITIES.include?(maturity)
        profiles = string_array(raw["profiles"], "#{id} profiles", allow_empty: false)
        unknown_profiles = profiles - @profiles.keys
        invalid!("#{id} references unknown profile #{unknown_profiles.first.inspect}") unless unknown_profiles.empty?
        constraints = parse_constraints(raw["constraints"], id)
        docs = references(raw["docs"], "#{id} docs")
        code = references(raw["code"], "#{id} code")

        Entry.new(
          id: id,
          title: raw["title"],
          description: raw["description"],
          maturity: maturity,
          profiles: profiles.freeze,
          constraints: constraints.freeze,
          docs: docs.freeze,
          code: code.freeze
        ).freeze
      end

      def parse_constraints(raw, id)
        invalid!("#{id} constraints must be a map") unless raw.is_a?(Hash)
        unknown = raw.keys.map(&:to_s) - CONSTRAINT_KEYS
        invalid!("#{id} constraints has unknown key #{unknown.first.inspect}") unless unknown.empty?

        CONSTRAINT_KEYS.to_h do |key|
          [ key, string_array(raw.fetch(key, []), "#{id} constraints.#{key}").freeze ]
        end
      end

      def references(raw, label)
        refs = string_array(raw, label, allow_empty: false)
        refs.each do |ref|
          invalid!("#{label} contains invalid reference #{ref.inspect}") if ref.start_with?("/") || ref.split("/").include?("..")
          resolved = begin
            File.realpath(File.join(@repo_root, ref))
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end
          unless resolved && resolved.start_with?("#{@repo_root}/") && File.file?(resolved)
            invalid!("#{label} contains invalid reference #{ref.inspect}")
          end
        end
        refs
      end

      def validate_scenarios!
        duplicate_name = @scenarios.group_by(&:name).find { |_name, matches| matches.size > 1 }
        invalid!("duplicate scenario name #{duplicate_name.first.inspect}") if duplicate_name

        primary_by_id = {}
        supporting_by_id = @entries_by_id.to_h { |id, _entry| [ id, [] ] }
        @scenarios.each do |scenario|
          primary = scenario.coverage.primary
          invalid!("scenario #{scenario.name.inspect} must declare exactly one coverage.primary") unless primary
          invalid!("scenario #{scenario.name.inspect} names unknown coverage ID #{primary.inspect}") unless @entries_by_id.key?(primary)
          if primary_by_id.key?(primary)
            invalid!(
              "duplicate primary owner for #{primary.inspect}: " \
              "#{primary_by_id.fetch(primary).name} and #{scenario.name}"
            )
          end
          primary_by_id[primary] = scenario

          scenario.coverage.supporting.each do |id|
            invalid!("scenario #{scenario.name.inspect} names unknown coverage ID #{id.inspect}") unless @entries_by_id.key?(id)
            supporting_by_id.fetch(id) << scenario
          end
        end
        @primary_by_id = primary_by_id.freeze
        @supporting_by_id = supporting_by_id.transform_values { |rows| rows.freeze }.freeze
      end

      def validate_profile!(profile)
        invalid!("invalid profile #{profile.inspect}") unless @profiles.key?(profile.to_s)
      end

      def searchable_text(entry)
        scenarios = [ @primary_by_id[entry.id], *@supporting_by_id[entry.id] ].compact
        [
          entry.id, entry.title, entry.description, entry.maturity,
          *entry.profiles, *entry.docs, *entry.code,
          *entry.constraints.values.flatten,
          *scenarios.flat_map do |scenario|
            [
              scenario.name, scenario.description, scenario.incident_id,
              scenario.sibling_task_id, *scenario.tags, *scenario.steps.map(&:kind)
            ]
          end
        ].compact.join("\n").downcase
      end

      def discovery_match(entry)
        primary = @primary_by_id[entry.id]
        {
          "id" => entry.id,
          "title" => entry.title,
          "description" => entry.description,
          "maturity" => entry.maturity,
          "profiles" => entry.profiles,
          "constraints" => entry.constraints,
          "docs" => entry.docs,
          "code" => entry.code,
          "primary_scenario" => primary && scenario_summary(primary),
          "supporting_scenarios" => @supporting_by_id[entry.id].sort_by(&:name).map { |scenario| scenario_summary(scenario) },
          "runnable_command" => runnable_primary(entry) && "bin/hive-e2e run --coverage #{entry.id}"
        }
      end

      def runnable_primary(entry)
        scenario = @primary_by_id[entry.id]
        return unless scenario
        return if scenario.pending || entry.maturity == "planned"

        scenario
      end

      def scenario_summary(scenario)
        {
          "name" => scenario.name,
          "pending" => scenario.pending,
          "tags" => scenario.tags,
          "incident_id" => scenario.incident_id,
          "sibling_task_id" => scenario.sibling_task_id
        }
      end

      def selection_payload(profile:, coverage_ids:, scenarios:, pending:, advisory:, planned:, replay_command:)
        {
          "schema" => "hive-e2e-selection",
          "schema_version" => Schemas.version_for("hive-e2e-selection"),
          "catalog_digest" => digest,
          "profile" => profile,
          "coverage_ids" => coverage_ids.sort,
          "scenarios" => scenarios.sort,
          "pending" => pending.sort,
          "advisory" => advisory.sort,
          "planned" => planned.sort,
          "replay_command" => replay_command
        }
      end

      def string_array(raw, label, allow_empty: true)
        unless raw.is_a?(Array) && raw.all? { |value| nonempty_string?(value) }
          invalid!("#{label} must be an array of non-empty strings")
        end
        invalid!("#{label} must not be empty") if !allow_empty && raw.empty?
        invalid!("#{label} values must be unique") unless raw.uniq.size == raw.size

        raw.map(&:to_s)
      end

      def nonempty_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def invalid!(reason)
        raise InvalidCatalog, "#{@path}: #{reason}"
      end
    end
  end
end
