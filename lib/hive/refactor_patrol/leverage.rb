require "open3"
require "set"

module Hive
  module RefactorPatrol
    class Leverage
      SIGNALS = %w[churn fan_in complexity coupling bug_density coverage_gap].freeze
      DEFAULT_CAPS = {
        "churn" => 20.0,
        "fan_in" => 20.0,
        "complexity" => 1_000.0,
        "coupling" => 20.0,
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
          "normalized" => normalized
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
        args = [ "git", "-C", @project_root, "log", "--format=", "--name-only" ]
        args << "#{changed_since}..HEAD" if changed_since
        args << "--"
        args.concat(Array(feature.owned_files))
        out, _err, status = @command_runner.call(*args)
        return 0 unless status.success?

        owned = Array(feature.owned_files).to_set
        out.lines.map(&:strip).count { |path| owned.include?(path) }
      rescue StandardError
        0
      end

      def fan_in(feature)
        needles = reference_needles(feature)
        return 0 if needles.empty?

        owned = Array(feature.owned_files).to_set
        tracked_files.count do |path|
          next false if owned.include?(path)

          content = read(path).downcase
          needles.any? { |needle| content.include?(needle.downcase) }
        end
      end

      def complexity(feature)
        Array(feature.owned_files).sum do |path|
          lines = read(path).lines
          nesting = lines.count { |line| line.match?(/\b(if|case|while|for|rescue|elsif|else|switch|catch)\b/) }
          lines.size + (nesting * 3)
        end
      end

      def coupling(feature, inbound = nil)
        owned = Array(feature.owned_files).to_set
        files = tracked_files
        outbound = Array(feature.owned_files).sum do |path|
          lowered = read(path).downcase
          files.count { |candidate| !owned.include?(candidate) && references_path?(lowered, candidate) }
        end
        outbound + (inbound || fan_in(feature))
      end

      def reference_needles(feature)
        Array(feature.entrypoints).flat_map do |entrypoint|
          basename = File.basename(entrypoint, File.extname(entrypoint))
          [
            entrypoint,
            entrypoint.sub(/\.[^.]+\z/, ""),
            basename
          ]
        end.compact.reject(&:empty?).uniq
      end

      # +lowered+ is the already-downcased content of an owned file; callers
      # hoist the downcase out of the per-candidate loop so it is computed
      # once per owned file rather than once per (owned file × candidate).
      def references_path?(lowered, path)
        stem = path.sub(/\.[^.]+\z/, "")
        lowered.include?(path.downcase) || lowered.include?(stem.downcase)
      end

      def tracked_files
        @tracked_files ||= compute_tracked_files
      end

      def compute_tracked_files
        out, _err, status = @command_runner.call("git", "-C", @project_root, "ls-files", "-z")
        files = status.success? ? out.split("\0").reject(&:empty?) : []
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @project_root).select do |path|
          File.file?(File.join(@project_root, path))
        end if files.empty?

        files.map { |path| path.tr("\\", "/") }
             .reject { |path| path.split("/").include?(".git") }
             .reject { |path| excluded?(path) }
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
          [ signal, cap.positive? ? [ value / cap, 1.0 ].min : 0.0 ]
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
        # Tracked files may be binary or non-UTF-8; scrub invalid byte
        # sequences so downcase/match? in the signal passes cannot raise
        # ArgumentError and abort the whole scan (R5/U4 graceful degradation).
        File.read(File.join(@project_root, path), encoding: "UTF-8").scrub("")
      rescue SystemCallError, ArgumentError
        ""
      end

      def capture3(*args)
        Open3.capture3(*args)
      end
    end
  end
end
