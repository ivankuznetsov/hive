require "open3"
require "set"
require "hive/patrol/architecture_mapper"
require "hive/patrol/source_reader"

module Hive
  module RefactorPatrol
    class Leverage
      SIGNALS = %w[churn fan_in complexity coupling bug_density coverage_gap].freeze
      DEFAULT_CAPS = {
        "churn" => 30.0,
        "fan_in" => 50.0,
        "complexity" => 20.0,
        "coupling" => 75.0,
        "bug_density" => 10.0,
        "coverage_gap" => 1.0
      }.freeze

      def self.score_proposal(hotspot, drivers)
        hotspot_breakdown = hotspot.is_a?(Hash) && hotspot["breakdown"].is_a?(Hash) ? hotspot["breakdown"] : {}
        seen = {}
        validated = Array(drivers).map do |driver|
          raise ArgumentError, "proposal leverage driver must be an object" unless driver.is_a?(Hash)

          signal = driver.fetch("signal")
          relief = driver.fetch("relief")
          mechanism = driver.fetch("mechanism").to_s.strip
          raise ArgumentError, "unknown proposal leverage signal #{signal.inspect}" unless SIGNALS.include?(signal)
          raise ArgumentError, "duplicate proposal leverage signal #{signal.inspect}" if seen[signal]
          unless relief.is_a?(Numeric) && relief.to_f.finite? && relief.to_f.between?(0.0, 1.0)
            raise ArgumentError, "proposal leverage relief must be between 0 and 1"
          end
          raise ArgumentError, "proposal leverage mechanism must be non-empty" if mechanism.empty?

          seen[signal] = true
          { "signal" => signal, "relief" => relief.to_f, "mechanism" => mechanism }
        rescue KeyError => e
          raise ArgumentError, "proposal leverage driver is missing #{e.key.inspect}"
        end
        breakdown = validated.to_h do |driver|
          signal = driver.fetch("signal")
          contribution = hotspot_breakdown.fetch(signal, 0).to_f * driver.fetch("relief").to_f
          [ signal, contribution.round(4) ]
        end

        {
          "score" => breakdown.values.sum.round(4),
          "breakdown" => breakdown,
          "drivers" => validated
        }
      end

      def initialize(project_root, cfg:, command_runner: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @command_runner = command_runner || method(:capture3)
        @source_reader = Hive::Patrol::SourceReader.new(@project_root)
      end

      def score(feature, changed_since: nil, changed_boost: false)
        raw = collect(feature, changed_since: changed_since)
        raw["churn"] += 5 if changed_boost
        normalized = normalize(raw)
        weights = configured_weights
        total_weight = weights.values.select(&:positive?).sum
        breakdown = {}
        score = 0.0

        SIGNALS.each do |signal|
          weight = weights.fetch(signal, 0.0).to_f
          next unless weight.positive?

          contribution = total_weight.positive? ? (normalized.fetch(signal) * weight / total_weight) : 0.0
          breakdown[signal] = contribution.round(4)
          score += contribution
        end

        {
          "scope" => "feature",
          "score" => score.round(4),
          "breakdown" => breakdown,
          "signals" => raw,
          "normalized" => normalized,
          "measurement" => architecture_scan.fetch(:measurement)
        }
      end

      def collect(feature, changed_since: nil)
        fan_in_count = fan_in(feature)
        {
          "churn" => churn(feature, changed_since: changed_since),
          "fan_in" => fan_in_count,
          "complexity" => complexity(feature),
          "coupling" => coupling(feature, fan_in_count),
          "bug_density" => 0,
          "coverage_gap" => 0
        }
      end

      private

      def churn(feature, changed_since:)
        owned = Array(feature.owned_files).to_set
        counts = churn_counts(changed_since)
        changes = owned.sum { |path| counts.fetch(path, 0) }
        owned.empty? ? 0 : (changes.to_f / owned.size).round(4)
      end

      def fan_in(feature)
        needles = reference_needles(feature)
        owned = Array(feature.owned_files).to_set
        roots = owned.filter_map { |path| component_roots[path] }.to_set
        edges = dependency_edges
        source_files.count do |path|
          next false if owned.include?(path)
          next false if roots.include?(component_roots[path])

          (Array(edges[path]) & owned.to_a).any? ||
            needles.any? { |needle| reference_present?(read(path), needle) }
        end
      end

      def complexity(feature)
        lines = Array(feature.owned_files).flat_map do |path|
          read(path).lines.reject { |line| line.strip.empty? }
        end
        return 0 if lines.empty?

        decisions = lines.sum do |line|
          line.scan(/\b(?:if|case|when|while|until|for|rescue|elsif|else|switch|catch|match)\b/).size
        end
        ((decisions.to_f * 100) / lines.size).round(4)
      end

      def coupling(feature, inbound = nil)
        owned = Array(feature.owned_files).to_set
        roots = owned.filter_map { |path| component_roots[path] }.to_set
        outbound = owned.flat_map { |path| Array(dependency_edges[path]) }
                        .reject do |path|
                          owned.include?(path) || roots.include?(component_roots[path])
                        end.uniq.size
        outbound + (inbound || fan_in(feature))
      end

      def reference_needles(feature)
        Array(feature.entrypoints).flat_map do |entrypoint|
          reference_needles_for(entrypoint)
        end.compact.reject(&:empty?).uniq
      end

      def reference_needles_for(path)
        normalized = path.to_s.tr("\\", "/")
        stem = normalized.sub(/\.[^.]+\z/, "")
        segments = stem.split("/")
        trimmed = if Hive::Patrol::ArchitectureMapper::SOURCE_ROOTS.any? do |root|
          root.casecmp?(segments.first.to_s)
        end
          segments.drop(1).join("/")
        else
          stem
        end
        basename = File.basename(stem)
        namespace = trimmed.split("/").map do |segment|
          segment.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map(&:capitalize).join
        end.reject(&:empty?).join("::")
        values = [ normalized, stem ]
        segments = trimmed.split("/").reject(&:empty?)
        segments.each_index do |index|
          suffix = segments.drop(index)
          next unless suffix.size >= 2

          module_path = suffix.join("/")
          values.concat([ module_path, module_path.tr("/", "."), module_path.tr("/", "\\") ])
        end
        values << namespace if segments.size >= 2 && !namespace.empty?
        values << basename if basename.length >= 8
        values.uniq
      end

      def reference_present?(content, needle)
        pattern = /(?<![A-Za-z0-9_])#{Regexp.escape(needle)}(?![A-Za-z0-9_])/i
        content.match?(pattern)
      end

      def churn_counts(changed_since)
        @churn_counts ||= {}
        key = changed_since.to_s
        @churn_counts[key] ||= begin
          args = [ "git", "-C", @project_root, "log", "--format=", "--name-only" ]
          args << "#{changed_since}..HEAD" if changed_since
          args << "--"
          out, _err, status = @command_runner.call(*args)
          status.success? ? out.lines.map(&:strip).reject(&:empty?).tally : {}
        rescue StandardError
          {}
        end
      end

      def architecture_scan
        @architecture_scan ||= begin
          mapper = Hive::Patrol::ArchitectureMapper.new(@project_root, cfg: @cfg)
          mapper.call(tracked_files)
          {
            component_roots: mapper.component_roots,
            edges: mapper.dependency_edges,
            source_files: (mapper.source_files + mapper.reserved_command_files).uniq.sort,
            measurement: { "status" => "complete", "diagnostics" => [] }
          }
        rescue StandardError => e
          message = e.message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub("?")[0, 500]
          {
            component_roots: {}, edges: {}, source_files: [],
            measurement: {
              "status" => "incomplete",
              "diagnostics" => [
                {
                  "kind" => "architecture_map_failed",
                  "error_class" => e.class.name,
                  "message" => message
                }
              ]
            }
          }
        end
      end

      def component_roots
        architecture_scan.fetch(:component_roots)
      end

      def dependency_edges
        architecture_scan.fetch(:edges)
      end

      def source_files
        architecture_scan.fetch(:source_files)
      end

      def tracked_files
        @tracked_files ||= compute_tracked_files
      end

      def compute_tracked_files
        out, _err, status = @command_runner.call("git", "-C", @project_root, "ls-files", "-z")
        files = status.success? ? out.split("\0").reject(&:empty?) : []
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @project_root).select do |path|
          @source_reader.regular_file?(path)
        end if files.empty?

        files.map { |path| path.tr("\\", "/") }
             .reject { |path| path.split("/").include?(".git") }
             .reject { |path| excluded?(path) }
             .select { |path| @source_reader.regular_file?(path) }
             .sort
      rescue StandardError
        []
      end

      def excluded?(path)
        exclude_globs.any? do |glob|
          File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
            path == glob ||
            path.start_with?("#{glob}/")
        end
      end

      def exclude_globs
        @exclude_globs ||= Array(@cfg.dig("refactor_patrol", "exclude")).map { |glob| glob.to_s.tr("\\", "/") }
      end

      def normalize(raw)
        SIGNALS.to_h do |signal|
          cap = DEFAULT_CAPS.fetch(signal)
          value = raw.fetch(signal, 0).to_f
          [ signal, cap.positive? && value.positive? ? value / (value + cap) : 0.0 ]
        end
      end

      def configured_weights
        weights = @cfg.dig("refactor_patrol", "leverage", "weights") || {}
        SIGNALS.to_h { |signal| [ signal, weights.fetch(signal, 0).to_f ] }
      end

      def read(path)
        # The Leverage instance is shared across every mapped feature and each
        # signal pass re-reads the tracked-file set, so memoize content to keep
        # the scan O(tracked_files) rather than O(features × tracked_files).
        content_cache[path] ||= read_uncached(path)
      end

      def content_cache
        @content_cache ||= {}
      end

      def read_uncached(path)
        @source_reader.read_utf8(path)
      end

      def capture3(*args)
        Open3.capture3(*args)
      end
    end
  end
end
