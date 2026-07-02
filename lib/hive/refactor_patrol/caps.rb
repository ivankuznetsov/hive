module Hive
  module RefactorPatrol
    class Caps
      PUBLIC_API_PATTERNS = [
        %r{\Alib/hive/cli\.rb\z},
        %r{\Aschemas/.*\.json\z},
        %r{\A(app|config)/routes\.rb\z},
        %r{\Adocs/},
        %r{\Awiki/}
      ].freeze
      DEPENDENCY_MANIFESTS = %w[
        Gemfile
        package.json
        pyproject.toml
        Cargo.toml
        go.mod
        composer.json
        mix.exs
        Package.swift
      ].freeze

      Result = Struct.new(:thesis, :blocked, :flags, keyword_init: true)

      def initialize(cfg)
        @cfg = cfg
      end

      def apply(thesis)
        risk = thesis.risk ||= {}
        risk["flags"] = Array(risk["flags"]).map(&:to_s)
        risk["public_api_details"] = Array(risk["public_api_details"])
        risk["cross_feature_details"] = Array(risk["cross_feature_details"])

        flags = []
        flags.concat(check_caps(thesis))
        flags.concat(detect_public_api(thesis))
        flags.concat(detect_cross_feature(thesis))
        flags.concat(detect_dependency_bumps(thesis))
        risk["flags"] |= flags
        Result.new(thesis: thesis, blocked: false, flags: flags)
      end

      private

      def check_caps(thesis)
        flags = []
        declared = thesis.risk.fetch("caps", {})
        caps_cfg = caps

        flags << "exceeds_max_files" if declared["est_files"].to_i > caps_cfg.fetch("max_files", 8).to_i
        flags << "exceeds_max_diff_lines" if declared["est_diff_lines"].to_i > caps_cfg.fetch("max_diff_lines", 400).to_i
        if caps_cfg.fetch("single_feature_only", true) && declared.key?("single_feature") && declared["single_feature"] != true
          flags << "not_single_feature"
        end
        flags
      end

      def detect_public_api(thesis)
        return [] if caps.fetch("allow_public_api_changes", false)

        paths = candidate_paths(thesis)
        details = paths.select { |path| public_api_path?(path) || public_api_content?(path) }.uniq
        # R9/R10 never-silently-clean: honor an agent-declared risk even when no
        # heuristic path matches, so a disallowed cap is always flagged.
        declared = thesis.risk["public_api_impact"] == true
        return [] if details.empty? && !declared

        thesis.risk["public_api_impact"] = true
        thesis.risk["public_api_details"] |= details
        [ "public_api_impact" ]
      end

      def detect_cross_feature(thesis)
        return [] if caps.fetch("allow_cross_feature", false)

        boundary = thesis.feature_boundary || {}
        # A feature's own entrypoints are part of its boundary; only paths
        # outside both owned_files and entrypoints count as cross-feature.
        own = (Array(boundary["owned_files"]) + Array(boundary["entrypoints"])).map { |path| path.to_s.tr("\\", "/") }
        out_of_boundary = candidate_paths(thesis).reject { |path| own.include?(path) }.uniq
        # R9/R10 never-silently-clean: honor an agent-declared risk even when no
        # out-of-boundary path is detected, so a disallowed cap is always flagged.
        declared = thesis.risk["cross_feature_impact"] == true
        return [] if out_of_boundary.empty? && !declared

        thesis.risk["cross_feature_impact"] = true
        thesis.risk["cross_feature_details"] |= out_of_boundary
        [ "cross_feature_impact" ]
      end

      def detect_dependency_bumps(thesis)
        return [] if caps.fetch("allow_dependency_bumps", false)

        manifests = candidate_paths(thesis).select { |path| dependency_manifest?(path) }
        mentions = DEPENDENCY_MANIFESTS.select do |manifest|
          thesis.proposed_refactor.to_s.include?(manifest) || thesis.problem.to_s.include?(manifest)
        end
        details = (manifests + mentions).uniq
        return [] if details.empty?

        # A dependency bump crosses the feature boundary, so flag the impact
        # too — otherwise populated cross_feature_details with
        # cross_feature_impact: false reads as inconsistent.
        thesis.risk["cross_feature_impact"] = true
        thesis.risk["cross_feature_details"] |= details
        [ "dependency_bump" ]
      end

      def candidate_paths(thesis)
        boundary = thesis.feature_boundary || {}
        paths = Array(boundary["owned_files"]) + Array(boundary["entrypoints"])
        paths.concat(Array(thesis.evidence).filter_map { |item| item["file"] if item.is_a?(Hash) })
        paths.map { |path| path.to_s.tr("\\", "/") }.reject(&:empty?)
      end

      def public_api_path?(path)
        PUBLIC_API_PATTERNS.any? { |pattern| path.match?(pattern) }
      end

      def public_api_content?(path)
        # Only genuine CLI command surfaces, not any *.rb whose name merely
        # contains the "cli" substring (e.g. client.rb). Matches bin/ scripts
        # and files named exactly cli.rb, mirroring PUBLIC_API_PATTERNS.
        path.start_with?("bin/") || File.basename(path) == "cli.rb"
      end

      def dependency_manifest?(path)
        DEPENDENCY_MANIFESTS.include?(File.basename(path))
      end

      def caps
        @cfg.dig("refactor_patrol", "caps") || {}
      end
    end
  end
end
