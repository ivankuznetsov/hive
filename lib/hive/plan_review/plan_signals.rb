require "digest"
require "pathname"
require "yaml"
require "hive/plan_review"
require "hive/secret_patterns"

module Hive
  module PlanReview
    module PlanSignals
      DEFAULT_MAX_BYTES = 256 * 1024
      DEFAULT_MAX_FILES = 5
      PATH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      MANDATORY_PATTERNS = [
        [ "auth_secrets_permissions", /\b(?:authentication|authorization|authn|authz|permissions?|secrets?|credentials?)\b/i ],
        [ "destructive_data_schema", /\b(?:drop|truncate|destructive|irreversible|schema migration|data migration)\b/i ],
        [ "public_compatibility", /\b(?:public (?:api|contract)|compatibility contract|breaking change)\b/i ],
        [ "concurrency_recovery_ownership", /\b(?:concurren(?:cy|t)|race condition|locking|recovery|ownership)\b/i ],
        [ "deployment_release_supply_chain", /\b(?:deploy(?:ment)?|release|publish(?:ing)?|supply[ -]chain)\b/i ]
      ].freeze
      MANDATORY_PATH_PATTERNS = {
        "auth_secrets_permissions" => %r{(?:\A|/)(?:auth|permissions?|secrets?|credentials?)(?:/|\.|\z)}i,
        "destructive_data_schema" => %r{(?:\A|/)(?:db/)?migrate(?:/|\z)|schema\.rb\z}i,
        "deployment_release_supply_chain" => %r{\A(?:\.github/workflows|packaging|deploy|release)(?:/|\z)}i
      }.freeze

      Result = Data.define(
        :valid, :plan_path, :plan_digest, :declared_files, :test_scenarios,
        :tests_explicit, :rollback_explicit, :local_scope, :size_within_limit,
        :mandatory_reasons, :uncertainties, :evidence
      ) do
        def valid? = valid

        def skip_eligible?
          valid? && mandatory_reasons.empty? && uncertainties.empty? && tests_explicit &&
            rollback_explicit && local_scope && size_within_limit && !declared_files.empty?
        end

        def to_h
          {
            "valid" => valid?,
            "plan_path" => plan_path,
            "plan_digest" => plan_digest,
            "declared_files" => declared_files,
            "test_scenarios" => test_scenarios,
            "tests_explicit" => tests_explicit,
            "rollback_explicit" => rollback_explicit,
            "local_scope" => local_scope,
            "size_within_limit" => size_within_limit,
            "skip_eligible" => skip_eligible?,
            "mandatory_reasons" => mandatory_reasons,
            "uncertainties" => uncertainties,
            "evidence" => evidence
          }
        end
      end

      module_function

      def analyze(plan_path:, task_folder:, max_bytes: DEFAULT_MAX_BYTES,
                  max_files: DEFAULT_MAX_FILES, protected_paths: [])
        path = File.expand_path(plan_path.to_s)
        task_root = File.expand_path(task_folder.to_s)
        return invalid(path, "plan_outside_task") unless confined?(path, task_root)

        stat = File.lstat(path)
        return invalid(path, "plan_symlink") if stat.symlink?
        return invalid(path, "plan_not_regular") unless stat.file?
        return invalid(path, "plan_too_large") if stat.size > max_bytes

        bytes = File.binread(path)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return invalid(path, "invalid_utf8") unless text.valid_encoding?

        parse(path:, text:, max_files:, protected_paths:)
      rescue Errno::ENOENT
        invalid(path || plan_path.to_s, "plan_missing")
      rescue SystemCallError, IOError
        invalid(path || plan_path.to_s, "plan_unreadable")
      end

      def parse(path:, text:, max_files:, protected_paths:)
        uncertainties = []
        metadata = frontmatter(text, uncertainties)
        declared_files = declared_paths(text, metadata, uncertainties)
        scenarios = test_scenarios(text, metadata)
        tests_explicit = !scenarios.empty? && declared_files.any? { |file| test_path?(file) }
        rollback_explicit = rollback_explicit?(text, metadata)
        production_files = declared_files.reject { |file| non_production_path?(file) }
        local_scope = local_scope?(production_files)
        size_within_limit = declared_files.length.between?(1, Integer(max_files))

        uncertainties << "files_not_declared" if declared_files.empty?
        uncertainties << "tests_not_explicit" unless tests_explicit
        uncertainties << "rollback_not_explicit" unless rollback_explicit
        uncertainties << "scope_not_local" unless local_scope
        uncertainties << "file_limit_exceeded" unless size_within_limit

        mandatory = mandatory_reasons(text, declared_files, protected_paths, uncertainties)
        digest = Digest::SHA256.hexdigest(text.b)
        evidence = {
          "declared_files" => declared_files,
          "production_files" => production_files,
          "test_scenario_count" => scenarios.length,
          "rollback_explicit" => rollback_explicit,
          "local_scope" => local_scope,
          "file_count" => declared_files.length
        }.freeze

        Result.new(
          valid: true,
          plan_path: path.freeze,
          plan_digest: digest.freeze,
          declared_files: declared_files.freeze,
          test_scenarios: scenarios.freeze,
          tests_explicit: tests_explicit,
          rollback_explicit: rollback_explicit,
          local_scope: local_scope,
          size_within_limit: size_within_limit,
          mandatory_reasons: mandatory.freeze,
          uncertainties: uncertainties.uniq.sort.freeze,
          evidence: evidence
        ).freeze
      rescue ArgumentError, TypeError
        invalid(path, "invalid_policy_limits")
      end

      def frontmatter(text, uncertainties)
        return {} unless text.start_with?("---\n")

        closing = text.index("\n---\n", 4)
        unless closing
          uncertainties << "malformed_frontmatter"
          return {}
        end
        raw = text.byteslice(4, closing - 4)
        if raw.bytesize > 64 * 1024
          uncertainties << "frontmatter_too_large"
          return {}
        end

        value = YAML.safe_load(raw, permitted_classes: [ Date ], permitted_symbols: [], aliases: false) || {}
        unless value.is_a?(Hash)
          uncertainties << "malformed_frontmatter"
          return {}
        end
        value.transform_keys(&:to_s)
      rescue Psych::Exception
        uncertainties << "malformed_frontmatter"
        {}
      end

      def declared_paths(text, metadata, uncertainties)
        candidates = Array(metadata["files"])
        files_section = section(text, "files")
        candidates.concat(files_section.scan(/`([^`]+)`/).flatten)
        candidates.concat(files_section.scan(/^\s*[-*]\s+([^`\s][^\n]*)$/).flatten)

        candidates.filter_map do |candidate|
          value = candidate.to_s.strip.sub(/\s+[—-].*\z/, "")
          next if value.empty?

          normalized = value.tr("\\", "/")
          if unsafe_relative_path?(normalized)
            uncertainties << "invalid_declared_path"
            next
          end
          normalized
        end.uniq.sort
      end

      def test_scenarios(text, metadata)
        values = Array(metadata["test_scenarios"]).map(&:to_s)
        values.concat(section(text, "test scenarios").scan(/^\s*(?:[-*]|\d+[.)])\s+(.+)$/).flatten)
        values.map(&:strip).reject(&:empty?).uniq
      end

      def rollback_explicit?(text, metadata)
        return true if metadata["rollback"].to_s.match?(/\S/)

        rollback = section(text, "rollback")
        rollback.match?(/\b(?:revert|restore|roll back|rollback|reversible)\b/i)
      end

      def section(text, name)
        label = Regexp.escape(name)
        boundary = '(?=^#{1,6}[ \t]+|^[ \t]*(?:[-*][ \t]+)?\*\*[^*\n]+:?\*\*(?=[ \t]|\r?$)|\z)'
        pattern = /(?:^\#{1,6}[ \t]+#{label}[ \t]*\r?$\n|^[ \t]*(?:[-*][ \t]+)?\*\*#{label}:?\*\*[ \t]*)(.*?)#{boundary}/im
        text.scan(pattern).flatten.join("\n")
      end

      def mandatory_reasons(text, files, protected_paths, uncertainties)
        evidence_text = text
        reasons = MANDATORY_PATTERNS.filter_map do |category, pattern|
          path = files.find { |file| MANDATORY_PATH_PATTERNS[category]&.match?(file) }
          match = affirmative_match(evidence_text, pattern)
          next unless path || match

          {
            "category" => category,
            "evidence" => path ? "path:#{path}" : bounded_excerpt(evidence_text, match.begin(0))
          }.freeze
        end
        if Hive::SecretPatterns.match?(evidence_text) &&
           reasons.none? { |reason| reason.fetch("category") == "auth_secrets_permissions" }
          reasons.unshift(
            {
              "category" => "auth_secrets_permissions",
              "evidence" => "literal_credential_pattern"
            }.freeze
          )
        end

        normalized_patterns = Array(protected_paths).filter_map do |pattern|
          normalized = pattern.to_s.tr("\\", "/")
          if unsafe_relative_path?(normalized)
            uncertainties << "invalid_protected_path_glob"
            next
          end
          normalized
        end
        files.each do |file|
          normalized_patterns.each do |pattern|
            next unless path_glob_match?(pattern, file)

            reasons << {
              "category" => "protected_path",
              "evidence" => "path:#{file}",
              "path" => file,
              "pattern" => pattern
            }.freeze
          end
        end
        reasons.freeze
      end

      def affirmative_match(text, pattern)
        offset = 0
        while (match = pattern.match(text, offset))
          return match unless explicitly_negated?(text, match)

          offset = [ match.end(0), match.begin(0) + 1 ].max
        end
        nil
      end
      private_class_method :affirmative_match

      def explicitly_negated?(text, match)
        line_start = text.rindex("\n", match.begin(0))&.+(1) || 0
        line_end = text.index("\n", match.end(0)) || text.length
        prefix = text.byteslice(line_start, match.begin(0) - line_start).to_s
        suffix = text.byteslice(match.end(0), line_end - match.end(0)).to_s
        clause_start = text.rindex(/[.!?;]/, match.begin(0) - 1)&.+(1) || 0
        clause_prefix = text.byteslice(clause_start, match.begin(0) - clause_start).to_s
        prefix.match?(/\b(?:no|without|excluding)\s+(?:[a-z-]+\s+){0,3}\z/i) ||
          prefix.match?(/\b(?:do(?:es)?|will|would|is|are)\s+not\s+(?:[a-z-]+\s+){0,3}\z/i) ||
          clause_prefix.gsub(/\s+/, " ").match?(
            /\b(?:do(?:es)?|will|would|is|are)\s+not\s+(?:[a-z-]+\s+){0,3}\z/i
          ) ||
          suffix.match?(/\A\s+(?:changes?\s+)?(?:is|are|remain(?:s)?)\s+(?:explicitly\s+)?(?:out of scope|unchanged)\b/i)
      end
      private_class_method :explicitly_negated?

      def local_scope?(production_files)
        return false if production_files.empty?

        roots = production_files.map { |file| file.split("/").first(2).join("/") }.uniq
        roots.one?
      end

      def test_path?(path)
        path.match?(%r{(?:\A|/)(?:test|tests|spec)(?:/|\z)|_(?:test|spec)\.rb\z}i)
      end

      def non_production_path?(path)
        test_path?(path) || path.match?(%r{\A(?:docs|wiki|raw)(?:/|\z)}i)
      end

      def unsafe_relative_path?(value)
        value.empty? || value.include?("\0") || value.start_with?("/") ||
          value.match?(%r{\A[A-Za-z]:/}) ||
          value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
      end

      def path_glob_match?(pattern, path)
        File.fnmatch?(pattern, path, PATH_FLAGS) ||
          (pattern.end_with?("/**") && path.start_with?(pattern.delete_suffix("**")))
      end

      def confined?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def bounded_excerpt(text, offset)
        line_start = text.rindex("\n", offset)&.+(1) || 0
        text.byteslice(line_start, 240).to_s.lines.first.to_s.strip
      end

      def invalid(path, reason)
        Result.new(
          valid: false,
          plan_path: path.to_s.freeze,
          plan_digest: nil,
          declared_files: [].freeze,
          test_scenarios: [].freeze,
          tests_explicit: false,
          rollback_explicit: false,
          local_scope: false,
          size_within_limit: false,
          mandatory_reasons: [].freeze,
          uncertainties: [ reason.freeze ].freeze,
          evidence: {}.freeze
        ).freeze
      end
    end
  end
end
