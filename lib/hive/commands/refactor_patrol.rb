require "json"
require "open3"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/patrol/mapper"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/collisions"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/leverage"
require "hive/refactor_patrol/reporter"
require "hive/refactor_patrol/reviewer"
require "hive/refactor_patrol/state_store"

module Hive
  module Commands
    class RefactorPatrol
      def initialize(project, json: false, dry_run: false, feature: nil, entrypoint: nil, path: nil, changed_since: nil,
                     mapper_factory: nil, reviewer_factory: nil, leverage_factory: nil,
                     caps_factory: nil, collisions_factory: nil)
        @project = project
        @json = json
        @dry_run = dry_run
        @feature_hint = feature
        @entrypoint_hint = entrypoint
        @raw_path_hints = Array(path).flatten.compact
        @path_hints = []
        @changed_since = changed_since
        @mapper_factory = mapper_factory || ->(root, cfg, state) { Hive::Patrol::Mapper.new(root, cfg: mapper_cfg(cfg), state: state, dry_run: @dry_run) }
        @reviewer_factory = reviewer_factory || ->(root, cfg, state) { Hive::RefactorPatrol::Reviewer.new(root, cfg: cfg, state: state, dry_run: @dry_run) }
        @leverage_factory = leverage_factory || ->(root, cfg) { Hive::RefactorPatrol::Leverage.new(root, cfg: cfg) }
        @caps_factory = caps_factory || ->(cfg) { Hive::RefactorPatrol::Caps.new(cfg) }
        @collisions_factory = collisions_factory || ->(root, state) { Hive::RefactorPatrol::Collisions.new(root, state: state) }
      end

      def call
        payload, theses = run_cycle
        emit(payload, theses)
      rescue Hive::Error => e
        emit_error(e)
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error(wrapped)
        raise wrapped
      end

      private

      def run_cycle
        entry, project_root, cfg = resolve_project!
        @path_hints = normalize_path_hints!(project_root)
        state = Hive::RefactorPatrol::StateStore.new(project_root)
        # A dry run must not create durable artifacts under
        # .hive-state/refactor_patrol/; all reads tolerate a missing dir.
        state.ensure! unless @dry_run

        features = scoped_features(project_root, cfg, state)
        reviewer = @reviewer_factory.call(project_root, cfg, state)
        theses = reviewer.call(features, leverage_by_feature: score_features(features, project_root, cfg))
        suppressed = guard_theses(theses, project_root, cfg, state)

        unless @dry_run
          persist(state, theses, suppressed)
          update_scan_state(state, project_root, cfg, reviewer)
        end
        [ build_payload(entry, project_root, cfg, state, features, theses, suppressed), theses ]
      end

      def resolve_project!
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "hive refactor-patrol: unknown project #{@project.inspect}" unless entry

        project_root = entry.fetch("path")
        cfg = Hive::Config.load(project_root)
        unless (cfg["refactor_patrol"] || {})["enabled"]
          raise Hive::ConfigError, "hive refactor-patrol: project #{entry.fetch('name').inspect} must opt in with refactor_patrol.enabled: true"
        end

        [ entry, project_root, cfg ]
      end

      def scoped_features(project_root, cfg, state)
        features = @mapper_factory.call(project_root, cfg, state).call
        apply_scope_hints(features, project_root)
      end

      def score_features(features, project_root, cfg)
        changed = changed_files(project_root)
        leverage = @leverage_factory.call(project_root, cfg)
        features.to_h do |feature|
          boost = @changed_since && !Array(changed).empty? && (Array(feature.owned_files) & Array(changed)).any?
          [ feature.id, leverage.score(feature, changed_since: @changed_since, changed_boost: boost) ]
        end
      end

      def guard_theses(theses, project_root, cfg, state)
        caps = @caps_factory.call(cfg)
        collisions = @collisions_factory.call(project_root, state)
        theses.filter_map do |thesis|
          caps.apply(thesis)
          collision = collisions.check(thesis)
          { "id" => thesis.id, "reason" => collision.reason, "reference" => collision.reference } if collision.suppressed
        end
      end

      def build_payload(entry, project_root, cfg, state, features, theses, suppressed)
        scanned_sha = @dry_run ? current_default_sha(project_root, cfg) : state.state["last_scanned_sha"].to_s
        @reporter = Hive::RefactorPatrol::Reporter.new(cfg)
        @reporter.envelope(
          project: entry.fetch("name"),
          project_root: project_root,
          dry_run: @dry_run,
          features: features,
          theses: theses,
          suppressed: suppressed,
          last_scanned_sha: scanned_sha
        )
      end

      def persist(state, theses, suppressed)
        suppressed_ids = suppressed.map { |item| item.fetch("id") }
        fingerprints = state.fingerprints
        theses.each do |thesis|
          state.write_thesis(thesis)
          next if suppressed_ids.include?(thesis.id)

          Hive::RefactorPatrol::Fingerprint.record_seen(fingerprints, thesis.fingerprint, thesis: thesis)
        end
        state.write_fingerprints(fingerprints)
      end

      def update_scan_state(state, project_root, cfg, reviewer)
        now_iso = Time.now.utc.iso8601
        if reviewer.respond_to?(:review_errors) && Array(reviewer.review_errors).any?
          state.update_state("last_run_at" => now_iso)
        else
          state.update_state("last_run_at" => now_iso, "last_scanned_sha" => current_default_sha(project_root, cfg))
        end
      end

      def apply_scope_hints(features, project_root)
        scoped =
          if @feature_hint
            features.select { |feature| feature.id == @feature_hint }
          elsif @entrypoint_hint
            features.select { |feature| Array(feature.entrypoints).include?(@entrypoint_hint) }
          elsif @path_hints.any?
            features.select do |feature|
              Array(feature.owned_files).any? do |path|
                @path_hints.any? { |hint| path == hint || path.start_with?("#{hint}/") }
              end
            end
          else
            features
          end

        return scoped unless @changed_since && (@feature_hint || @entrypoint_hint || @path_hints.any?)

        changed = changed_files(project_root)
        # A git failure yields nil (distinct from an empty "no changes" diff);
        # degrade to the scoped set rather than filtering it down to zero, in
        # keeping with the churn/leverage graceful-degradation posture.
        return scoped if changed.nil?

        scoped.select { |feature| (Array(feature.owned_files) & changed).any? }
      end

      def changed_files(project_root)
        return @changed_files if defined?(@changed_files)

        @changed_files = compute_changed_files(project_root)
      end

      def compute_changed_files(project_root)
        return [] unless @changed_since

        out, _err, status = Open3.capture3("git", "-C", project_root, "diff", "--name-only", @changed_since, "HEAD")
        # nil signals a git failure so callers can degrade gracefully; [] means
        # the diff succeeded with no changed files.
        return nil unless status.success?

        out.lines.map { |line| line.strip.tr("\\", "/") }.reject(&:empty?)
      rescue StandardError
        nil
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        out, _err, status = Open3.capture3("git", "-C", project_root, "rev-parse", branch)
        return "" unless status.success?

        out.strip
      end

      def normalize_path_hints!(project_root)
        root = File.realpath(project_root)
        @raw_path_hints.map do |raw|
          value = raw.to_s.tr("\\", "/")
          parts = value.split("/")
          valid = value.match?(%r{\A[A-Za-z0-9_.\-/]+\z}) &&
                  !value.start_with?("/", "-") &&
                  parts.none? { |part| part.empty? || %w[. ..].include?(part) } &&
                  File.expand_path(value, root).start_with?("#{root}#{File::SEPARATOR}")
          raise Hive::ConfigError, "hive refactor-patrol: unsafe --path #{raw.inspect}" unless valid

          value
        end.uniq
      end

      def mapper_cfg(cfg)
        clone = Hive::Config.deep_dup(cfg)
        clone["patrol"] = (clone["patrol"] || {}).merge(
          "include" => cfg.dig("refactor_patrol", "include"),
          "exclude" => cfg.dig("refactor_patrol", "exclude"),
          "review" => cfg.dig("refactor_patrol", "review")
        )
        clone
      end

      def emit(payload, theses)
        if @json
          puts JSON.generate(payload)
        else
          puts @reporter.text(payload, theses)
        end
        payload
      end

      def emit_error(error)
        return unless @json

        puts JSON.generate(
          "schema" => "hive-refactor-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol"),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "error",
          "exit_code" => error.exit_code,
          "message" => error.message
        )
      end
    end
  end
end
