require "digest"
require "json"
require "time"
require "cgi"
require "yaml"
require "hive/daily_digest/materiality"
require "hive/daily_digest/source_health"
require "hive/daily_digest/task_creation_receipt"
require "hive/task_journal"
require "hive/markers"
require "hive/workflows/registry"
require "hive/gh"

module Hive
  module DailyDigest
    # Containment-safe adapter for one registered project's durable evidence.
    # It never calls GitHub or PRDigest and never uses mtime as activity time.
    class ProjectSource
      MAX_JOURNAL_BYTES = 16 * 1024 * 1024
      Result = Data.define(:project, :facts, :attention, :gaps, :frontier, :health)
      class SourceUnavailable < DailyDigest::Error; end

      def initialize(project:, starts_at:, ends_at:, known_stage_dirs: nil,
                     observed_at: -> { Time.now.utc })
        @project = stringify(project)
        @starts_at = normalize_time(starts_at)
        @ends_at = normalize_time(ends_at)
        @known_stage_dirs = Array(known_stage_dirs || default_stage_dirs).map(&:to_s).uniq.freeze
        @observed_at = observed_at
        @pr_core_cache = {}
      end

      def collect
        @collection_observed_at = normalize_time(@observed_at.call)
        state_root = verified_state_root!
        stages_root = verified_stages_root!(state_root)

        facts = []
        boundary_records = Hash.new { |hash, key| hash[key] = [] }
        gaps = unknown_stage_gaps(stages_root)
        fingerprints = []
        task_folders = task_directories(stages_root, gaps)
        task_folders.each do |task_folder|
          boundary_records[task_folder]
          collect_creation(task_folder, facts, gaps, fingerprints)
          collect_journal(task_folder, facts, gaps, fingerprints, boundary_records)
        end
        attention = boundary_attention(boundary_records)
        gaps.concat(boundary_history_gaps(task_folders, attention))
        facts = facts.uniq { |fact| fact.fetch("fact_id") }
                     .sort_by { |fact| [ fact.fetch("occurred_at"), fact.fetch("fact_id") ] }
        gaps = gaps.uniq { |gap| gap.fetch("gap_id") }
                   .sort_by { |gap| [ gap.fetch("source"), gap.fetch("scope"), gap.fetch("gap_id") ] }
        frontier = {
          "source" => "task_journal",
          "project_id" => @project.fetch("project_id"),
          "observed_at" => iso(observation_time),
          "fingerprints" => fingerprints.uniq.sort
        }
        health = gaps.empty? ?
          SourceHealth.healthy(source: "project_state", scope: @project.fetch("name"),
                               freshness_at: frontier.fetch("observed_at")) :
          SourceHealth.new(source: "project_state", scope: @project.fetch("name"),
                           status: "partial", freshness_at: frontier.fetch("observed_at"), gap: nil)
        Result.new(project: project_identity, facts: facts.freeze, attention: attention.freeze,
                   gaps: gaps.freeze, frontier: frontier.freeze, health: health)
      rescue SourceUnavailable
        raise
      rescue SystemCallError, IOError => error
        raise SourceUnavailable, "registered project evidence is unavailable (#{error.class})"
      end

      private

      def verified_state_root!
        path = @project["hive_state_path"] || File.join(@project.fetch("path"), ".hive-state")
        expanded = File.expand_path(path)
        raise SourceUnavailable, "registered project state is unavailable" unless File.directory?(expanded)
        raise SourceUnavailable, "registered project state cannot be a symlink" if File.symlink?(expanded)

        project_root = File.realpath(File.expand_path(@project.fetch("path")))
        real = File.realpath(expanded)
        unless real == project_root || real.start_with?("#{project_root}#{File::SEPARATOR}")
          raise SourceUnavailable, "registered project state escapes its project root"
        end
        real
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        raise SourceUnavailable, "registered project state is unavailable"
      end

      def default_stage_dirs
        Hive::Workflows::Registry.workflows.values.flat_map(&:stage_dirs).uniq
      end

      def verified_stages_root!(state_root)
        path = File.join(state_root, "stages")
        unless File.directory?(path) && !File.symlink?(path)
          raise SourceUnavailable, "registered project has no readable Hive stages"
        end

        real = File.realpath(path)
        unless real.start_with?("#{state_root}#{File::SEPARATOR}")
          raise SourceUnavailable, "registered project stages escape its state root"
        end
        real
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        raise SourceUnavailable, "registered project has no readable Hive stages"
      end

      def unknown_stage_gaps(stages_root)
        Dir.children(stages_root).sort.filter_map do |name|
          path = File.join(stages_root, name)
          next unless File.directory?(path) || File.symlink?(path)
          next if @known_stage_dirs.include?(name)
          next if !File.symlink?(path) && directory_empty?(path)

          scoped_gap("unknown_stage", "unknown non-empty stage bucket", task_slug: nil,
                     scope: "#{@project.fetch('name')}:#{name}")
        end
      end

      def task_directories(stages_root, gaps)
        @known_stage_dirs.sort.flat_map do |stage|
          stage_root = File.join(stages_root, stage)
          next [] unless File.exist?(stage_root) || File.symlink?(stage_root)
          unless safe_stage_root?(stage_root, stages_root)
            gaps << scoped_gap(
              "unsafe_stage_path", "stage directory escaped the Hive stages root",
              task_slug: nil, scope: "#{@project.fetch('name')}:#{stage}"
            )
            next []
          end

          Dir.children(stage_root).sort.filter_map do |name|
            candidate = File.join(stage_root, name)
            if unsafe_task_path?(candidate, stage_root)
              gaps << scoped_gap("unsafe_task_path", "task directory escaped its stage root",
                                 task_slug: name)
              next
            end
            candidate if File.directory?(candidate)
          end
        end
      end

      def safe_stage_root?(stage_root, stages_root)
        return false if File.symlink?(stage_root) || !File.directory?(stage_root)

        real = File.realpath(stage_root)
        real.start_with?("#{File.realpath(stages_root)}#{File::SEPARATOR}")
      rescue SystemCallError
        false
      end

      def unsafe_task_path?(candidate, stage_root)
        return true if File.symlink?(candidate)

        real_stage = File.realpath(stage_root)
        real = File.realpath(candidate)
        !(real.start_with?("#{real_stage}#{File::SEPARATOR}"))
      rescue SystemCallError
        true
      end

      def collect_creation(task_folder, facts, gaps, fingerprints)
        path = TaskCreationReceipt.path(task_folder)
        return unless File.exist?(path) || File.symlink?(path)
        if File.symlink?(path)
          gaps << scoped_gap("unsafe_creation_receipt", "task creation receipt is not a regular file",
                             task_slug: File.basename(task_folder))
          return
        end

        receipt = TaskCreationReceipt.read!(task_folder)
        fingerprints << Digest::SHA256.file(path).hexdigest
        return unless in_window?(receipt.fetch("created_at"))

        facts << Materiality.creation_fact(receipt)
      rescue TaskCreationReceipt::Error, SystemCallError, IOError
        gaps << scoped_gap("malformed_creation_receipt", "task creation receipt is unreadable",
                           task_slug: File.basename(task_folder))
      end

      def collect_journal(task_folder, facts, gaps, fingerprints, boundary_records)
        path = File.join(task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        return unless File.exist?(path) || File.symlink?(path)
        if File.symlink?(path)
          gaps << scoped_gap("unsafe_journal", "task journal is not a regular file",
                             task_slug: File.basename(task_folder))
          return
        end
        stat = File.lstat(path)
        unless stat.file? && stat.size <= MAX_JOURNAL_BYTES
          gaps << scoped_gap("journal_too_large", "task journal exceeds the collection bound",
                             task_slug: File.basename(task_folder))
          return
        end
        bytes = File.binread(path, MAX_JOURNAL_BYTES + 1)
        fingerprints << Digest::SHA256.hexdigest(bytes)
        bytes.each_line.with_index(1) do |line, index|
          next if line.strip.empty?

          record = JSON.parse(line)
          unless record.is_a?(Hash)
            gaps << scoped_gap(
              "malformed_journal", "task journal contains an invalid row",
              task_slug: File.basename(task_folder), discriminator: index
            )
            next
          end
          next unless relevant_record?(record)

          boundary_records[task_folder] << record if before_boundary?(record["occurred_at"])
          record = enrich_pr_evidence(task_folder, record)

          result = Materiality.classify(
            record, project: @project, observed_at: observation_time
          )
          if result.disposition == :fact
            if in_window?(result.value.fetch("occurred_at"))
              facts << with_task_url(result.value)
              gaps << incomplete_pr_gap(record, task_folder) if incomplete_pr_evidence?(record)
            end
          elsif result.disposition == :gap
            gaps << result.value
          end
        rescue JSON::ParserError
          gaps << scoped_gap("malformed_journal", "task journal contains an invalid row",
                             task_slug: File.basename(task_folder), discriminator: index)
        end
      rescue SystemCallError, IOError
        gaps << scoped_gap("unreadable_journal", "task journal could not be read",
                           task_slug: File.basename(task_folder))
      end

      def relevant_record?(record)
        record.is_a?(Hash) && record["event_type"] == "activity_recorded"
      end

      def enrich_pr_evidence(task_folder, record)
        payload = stringify(record["payload"] || {})
        return record unless %w[pr_observed check_observed review_observed merge_observed]
          .include?(payload["activity_kind"])

        core = pr_core(task_folder)
        payload["pr_url"] ||= core["pr_url"]
        payload["pr_number"] ||= core["pr_number"]
        payload["head_oid"] ||= payload["commit_oid"] || core["head_oid"]
        payload["draft"] = core["draft"] if payload["draft"].nil? && core.key?("draft")
        stringify(record).merge("payload" => payload)
      end

      def pr_core(task_folder)
        return @pr_core_cache[task_folder] if @pr_core_cache.key?(task_folder)

        @pr_core_cache[task_folder] = load_pr_core(task_folder)
      end

      def load_pr_core(task_folder)
        path = File.join(task_folder, "pr.md")
        return {} unless File.file?(path) && !File.symlink?(path)

        body = File.binread(path, 128 * 1024 + 1)
        return {} if body.bytesize > 128 * 1024

        match = body.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
        return {} unless match

        raw = YAML.safe_load(
          match[1], permitted_classes: [], permitted_symbols: [], aliases: false
        )
        return {} unless raw.is_a?(Hash)

        raw = stringify(raw)
        parsed = Hive::Gh.parse_pull_request_url(raw["pr_url"] || raw["url"])
        return {} unless parsed

        declared = Integer(raw["pr_number"], exception: false)
        return {} if declared && declared != parsed.fetch("number")

        head = raw["head_oid"].to_s.downcase
        head = nil unless head.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
        {
          "pr_url" => parsed.fetch("url"),
          "pr_number" => parsed.fetch("number"),
          "head_oid" => head,
          "draft" => raw["hosted_state"] == "draft" || raw["is_draft"] == true
        }.compact
      rescue Psych::Exception, SystemCallError, IOError
        {}
      end

      def incomplete_pr_evidence?(record)
        payload = stringify(record["payload"] || {})
        return false unless %w[pr_observed check_observed review_observed merge_observed]
          .include?(payload["activity_kind"])

        required = case payload["activity_kind"]
        when "check_observed" then %w[pr_number pr_url head_oid check_state]
        when "review_observed" then %w[pr_number pr_url head_oid review_state]
        else %w[pr_number pr_url head_oid pr_state]
        end
        required.any? { |key| payload[key].nil? || payload[key].to_s.empty? }
      end

      def incomplete_pr_gap(record, task_folder)
        Materiality.build_gap(
          source: "github", scope: "#{@project.fetch('name')}:#{File.basename(task_folder)}",
          reason_code: "pr_evidence_incomplete",
          reason: "Hive-owned pull request evidence lacks a required identity or outcome field",
          observed_at: record["observed_at"] || observation_time,
          project_id: @project["project_id"], task_slug: File.basename(task_folder)
        )
      end

      def before_boundary?(value)
        normalize_time(value) < @ends_at
      rescue ArgumentError, TypeError
        false
      end

      def boundary_attention(records_by_task)
        records_by_task.flat_map do |task_folder, records|
          open_questions = {}
          active_holds = {}
          failure = nil
          records.sort_by do |record|
            [ normalize_time(record["occurred_at"]), record["event_id"].to_s ]
          rescue ArgumentError, TypeError
            [ Time.at(0).utc, record["event_id"].to_s ]
          end.each do |record|
            payload = stringify(record["payload"] || {})
            case payload["activity_kind"]
            when "question_asked"
              key = payload["question_id"] || payload["question_fingerprint"]
              open_questions[key.to_s] = record unless key.to_s.empty?
            when "answer_recorded"
              key = payload["question_id"]
              open_questions.delete(key.to_s) unless key.to_s.empty?
            when "hold_recorded", "resource_limit_observed"
              key = (payload["hold_kind"] || payload["resource_kind"] || payload["kind"] || "hold").to_s
              if %w[cleared released recovered ended inactive].include?(payload["state"].to_s) ||
                 %w[recovered completed].include?(payload["outcome"].to_s)
                active_holds.delete(key)
              else
                active_holds[key] = record
              end
            when "session_finished"
              failure = record if failed_boundary_session?(payload)
            when "recovery_recorded"
              if %w[recovered complete completed resumed retrying].include?(payload["outcome"].to_s)
                failure = nil
                active_holds.clear
              end
            end
          end
          question_items = open_questions.values.map do |record|
            attention_item("unanswered", record, task_folder, state: "waiting_on_you")
          end
          hold_items = active_holds.values.map do |record|
            attention_item("blocked", record, task_folder, state: "blocked")
          end
          failure_items = failure ? [ attention_item("failed", failure, task_folder, state: "failed") ] : []
          question_items + hold_items + failure_items
        end.uniq { |item| item.fetch("attention_id") }
          .sort_by { |item| [ item.fetch("kind"), item.fetch("project"), item.fetch("task_slug") ] }
      end

      def attention_item(kind, record, task_folder, state:)
        at = normalize_time(record.fetch("occurred_at"))
        task = stringify(record["task"] || {})
        slug = task["slug"].to_s.empty? ? File.basename(task_folder) : task["slug"].to_s
        identity = [ kind, @project["project_id"], slug, record["event_id"] ].join("\0")
        item = {
          "attention_id" => "attention:#{Digest::SHA256.hexdigest(identity)}",
          "kind" => kind,
          "project_id" => @project.fetch("project_id"),
          "project" => @project.fetch("name"),
          "task_id" => task["id"]&.to_s,
          "task_slug" => slug,
          "stage" => record["stage"].to_s,
          "state" => state,
          "waiting_since" => at.utc.iso8601(6),
          "waiting_age_seconds" => [ (attention_boundary - at).floor, 0 ].max,
          "task_url" => task_url(slug, anchor: "task-questions")
        }
        item["waiting_age_seconds"] = nil if at > attention_boundary
        item
      end

      def boundary_history_gaps(task_folders, attention)
        known = attention.to_h { |item| [ item.fetch("task_slug"), true ] }
        task_folders.filter_map do |task_folder|
          slug = File.basename(task_folder)
          next if known[slug]
          next unless boundary_marker?(task_folder)

          scoped_gap(
            "boundary_history_missing",
            "durable entry into the current attention state is unavailable",
            task_slug: slug, scope: "#{@project.fetch('name')}:#{slug}"
          )
        end
      end

      def boundary_marker?(task_folder)
        stage_dir = File.basename(File.dirname(task_folder))
        stage = Hive::Workflows::Registry.workflows.values.flat_map(&:stages).find do |candidate|
          candidate.dir == stage_dir
        end
        return false unless stage

        marker = Hive::Markers.current(File.join(task_folder, stage.state_file))
        %i[waiting execute_waiting review_waiting error review_error].include?(marker.name)
      rescue Hive::Error, SystemCallError, IOError
        false
      end

      def with_task_url(fact)
        slug = fact["task_slug"].to_s
        return fact if slug.empty?

        fact.merge("task_url" => task_url(slug))
      end

      def task_url(slug, anchor: nil)
        path = "/tasks/#{url_component(@project.fetch('name'))}/#{url_component(slug)}"
        anchor ? "#{path}##{anchor}" : path
      end

      def attention_boundary
        [ @ends_at, observation_time ].min
      end

      def failed_boundary_session?(payload)
        %w[failed error timeout timed_out interrupted resource_exhausted].include?(payload["outcome"].to_s) ||
          %w[failed unhealthy].include?(payload["health"].to_s) || payload["timed_out"] == true
      end

      def url_component(value)
        CGI.escape(value.to_s).gsub("+", "%20")
      end

      def in_window?(value)
        time = normalize_time(value)
        time >= @starts_at && time < @ends_at
      rescue ArgumentError, TypeError
        false
      end

      def scoped_gap(reason_code, reason, task_slug:, scope: @project.fetch("name"), discriminator: nil)
        scope = "#{scope}:#{discriminator}" if discriminator
        Materiality.build_gap(
          source: "project_state", scope: scope, reason_code: reason_code, reason: reason,
          observed_at: observation_time, project_id: @project["project_id"], task_slug: task_slug
        )
      end

      def directory_empty?(path)
        Dir.empty?(path)
      rescue SystemCallError
        false
      end

      def project_identity
        %w[project_id registration_id name].each_with_object({}) do |key, out|
          out[key] = @project[key] if @project.key?(key)
        end
      end

      def stringify(value)
        value.to_h.each_with_object({}) { |(key, child), out| out[key.to_s] = child }
      end

      def normalize_time(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end

      def iso(value) = normalize_time(value).iso8601(6)

      def observation_time
        @collection_observed_at || normalize_time(@observed_at.call)
      end
    end
  end
end
