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
          "score" => score.round(4),
          "breakdown" => breakdown,
          "signals" => raw,
          "normalized" => normalized
        }
      end

      def collect(feature, changed_since: nil)
        {
          "churn" => churn(feature, changed_since: changed_since),
          "fan_in" => fan_in(feature),
          "complexity" => complexity(feature),
          "coupling" => coupling(feature),
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

      def coupling(feature)
        owned = Array(feature.owned_files).to_set
        files = tracked_files
        outbound = Array(feature.owned_files).sum do |path|
          content = read(path)
          files.count { |candidate| !owned.include?(candidate) && references_path?(content, candidate) }
        end
        inbound = fan_in(feature)
        outbound + inbound
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

      def references_path?(content, path)
        stem = path.sub(/\.[^.]+\z/, "")
        lowered = content.downcase
        lowered.include?(path.downcase) || lowered.include?(stem.downcase)
      end

      def tracked_files
        out, _err, status = @command_runner.call("git", "-C", @project_root, "ls-files", "-z")
        files = status.success? ? out.split("\0").reject(&:empty?) : []
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @project_root).select do |path|
          File.file?(File.join(@project_root, path))
        end if files.empty?

        files.map { |path| path.tr("\\", "/") }.reject { |path| path.split("/").include?(".git") }.sort
      rescue StandardError
        []
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
        File.read(File.join(@project_root, path))
      rescue SystemCallError, ArgumentError
        ""
      end

      def capture3(*args)
        Open3.capture3(*args)
      end
    end
  end
end
