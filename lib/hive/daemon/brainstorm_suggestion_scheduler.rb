# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "hive/agent_profiles"
require "hive/attempts/generation"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/stages"
require "hive/stages/base"
require "hive/task"

module Hive
  module Daemon
    # Reconciles advisory suggestions for every unanswered coding-brainstorm
    # slot. Context selection and provider execution happen outside the task
    # lock; only short inventory/CAS sections run while the lock is held.
    class BrainstormSuggestionScheduler
      STAGE = Hive::Stages::SHORT_TO_FULL.fetch("brainstorm")
      MAX_WORKERS = 4
      ORPHAN_GRACE_SEC = 30
      SHUTDOWN_GRACE_SEC = 5
      BACKOFF_SECONDS = [ 60, 300, 900 ].freeze

      Job = Struct.new(:token, :thread, keyword_init: true)
      Slot = Data.define(
        :ordinal, :round, :question_number, :question_text,
        :question_fingerprint, :question_id, :brainstorm_generation
      )

      def initialize(logger: nil, context_factory: nil, runner_factory: nil,
                     config_loader: nil, worker_launcher: nil, clock: nil,
                     max_workers: MAX_WORKERS)
        @logger = logger
        @context_factory = context_factory || method(:capture_context)
        @runner_factory = runner_factory || method(:build_runner)
        @config_loader = config_loader || ->(root) { Hive::Config.load(root) }
        @worker_launcher = worker_launcher || ->(work) { Thread.new(&work) }
        @clock = clock || -> { Time.now.utc }
        @max_workers = Integer(max_workers)
        @jobs = {}
        @next_launch_at = {}
        @task_next_launch_at = {}
        @mutex = Mutex.new
      end

      def startup!
        removed = Hive::BrainstormSuggestions::Runner.sweep_inactive!
        log(:brainstorm_suggestion_bundle_sweep, removed: removed) if removed.positive?
        removed
      end

      def tick(rows:, now: @clock.call, complete: true)
        active = []
        Array(rows).each do |row|
          if eligible_row?(row)
            cfg = config_for(row)
            if cfg&.dig("brainstorm", "suggestions", "enabled") == true
              active << [ row, cfg ]
              reconcile_row(row, cfg, now: now)
              next
            end
          end
          if brainstorm_worker_row?(row)
            cancel_task(row.folder)
          else
            cleanup_row(row)
          end
        end
        cancel_missing(active.map { |row, _cfg| File.expand_path(row.folder.to_s) }) if complete
        active.length
      rescue StandardError => error
        log(:brainstorm_suggestion_scheduler_error, error: bounded_error(error))
        0
      end

      def shutdown
        jobs = @mutex.synchronize { @jobs.values.dup }
        jobs.each { |job| job.token.cancel! }
        deadline = monotonic_now + SHUTDOWN_GRACE_SEC
        jobs.each do |job|
          remaining = deadline - monotonic_now
          break unless remaining.positive?

          job.thread&.join(remaining)
        end
        jobs.each { |job| job.thread&.kill if job.thread&.alive? }
        @mutex.synchronize do
          @jobs.clear
          @next_launch_at.clear
          @task_next_launch_at.clear
        end
      end

      private

      def eligible_row?(row)
        row && row.folder && row.stage.to_s == STAGE &&
          Hive::Workflows.coding_id?(row.workflow) && File.directory?(row.folder.to_s) &&
          File.file?(state_path(row.folder)) && waiting_row?(row)
      rescue StandardError
        false
      end

      def waiting_row?(row)
        row.action.to_s == Hive::Schemas::TaskActionKind::NEEDS_INPUT || row.marker.to_s == "waiting"
      end

      def brainstorm_worker_row?(row)
        row && row.folder && row.stage.to_s == STAGE &&
          Hive::Workflows.coding_id?(row.workflow) && row.marker.to_s != "complete"
      rescue StandardError
        false
      end

      def config_for(row)
        project_root = Hive::Task.new(row.folder.to_s).project_root
        @config_loader.call(project_root)
      rescue Hive::Error, SystemCallError, IOError, ArgumentError => error
        log(
          :brainstorm_suggestion_unavailable,
          project: row.project, slug: row.slug, reason: bounded_error(error)
        )
        nil
      end

      def reconcile_row(row, cfg, now:)
        slots = inventory_slots(row.folder)
        prune_removed_questions(row.folder, slots)
        unless slots.any?
          cleanup_task(row.folder)
          return
        end

        seed_records(row, slots, now: now)
        slots.each { |slot| schedule(row, cfg, slot, now: now) }
      rescue Hive::ConcurrentRunError
        log(:brainstorm_suggestion_deferred, project: row.project, slug: row.slug, reason: "task_lock_busy")
      rescue Hive::Error, SystemCallError, IOError => error
        log(
          :brainstorm_suggestion_unavailable,
          project: row.project, slug: row.slug, reason: bounded_error(error)
        )
      end

      def inventory_slots(task_root)
        parsed = Hive::BrainstormParser.parse(state_path(task_root))
        generation = brainstorm_generation(parsed)
        incarnation = task_incarnation(task_root)
        parsed.each_with_index.filter_map do |question, index|
          next if question.answered?

          fingerprint = Hive::BrainstormParser.question_fingerprint(question.text)
          Slot.new(
            ordinal: index + 1,
            round: question.round,
            question_number: question.n,
            question_text: question.text,
            question_fingerprint: fingerprint,
            question_id: question_id(incarnation, fingerprint, index + 1),
            brainstorm_generation: generation
          )
        end
      end

      def seed_records(row, slots, now:)
        task_root = row.folder.to_s
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_reconcile", slug: row.slug },
          create: false
        ) do
          current_slots = inventory_slots(task_root)
          return unless slot_identities(current_slots) == slot_identities(slots)

          incarnation = task_incarnation(task_root)
          generation = task_generation(task_root)
          store = Hive::BrainstormSuggestions::Store.new(task_root)
          store.update do |document|
            current_ids = current_slots.map(&:question_id)
            records = document.fetch("records").select do |record|
              current_ids.include?(record["question_id"])
            end
            current_slots.each do |slot|
              next if records.any? { |record| record["question_id"] == slot.question_id }

              records << seed_record(slot, now: now)
            end
            document.merge(
              "task_incarnation" => incarnation,
              "task_generation" => generation,
              "brainstorm_generation" => current_slots.first&.brainstorm_generation,
              "recipe_version" => Hive::BrainstormSuggestions::ContextBundle::RECIPE_VERSION,
              "records" => records.sort_by { |record| record.fetch("ordinal") },
              "updated_at" => now.utc.iso8601(6)
            )
          end
        end
      end

      def seed_record(slot, now:)
        {
          "question_id" => slot.question_id,
          "ordinal" => slot.ordinal,
          "round" => slot.round,
          "question_number" => slot.question_number,
          "question_fingerprint" => slot.question_fingerprint,
          "input_binding" => pending_binding(slot),
          "suggestion_binding" => nil,
          "state" => "loading",
          "text" => nil,
          "rationale" => nil,
          "provenance" => [],
          "safe_reason" => nil,
          "retryable" => false,
          "dismissed" => false,
          "attempt_id" => nil,
          "candidate_id" => nil,
          "requested_at" => nil,
          "updated_at" => now.utc.iso8601(6),
          "next_retry_at" => nil,
          "automatic_attempts" => 0,
          "input_epoch" => nil,
          "error_code" => nil
        }
      end

      def schedule(row, cfg, slot, now:)
        key = [ File.expand_path(row.folder.to_s), slot.question_id ]
        token = Hive::BrainstormSuggestions::Runner::Cancellation.new
        @mutex.synchronize do
          return if @jobs.key?(key) || @jobs.length >= @max_workers
          return if @next_launch_at[key] && now < @next_launch_at[key]

          @jobs[key] = Job.new(token: token, thread: nil)
          @next_launch_at[key] = now + cfg.dig("brainstorm", "suggestions", "coalesce_window_sec").to_i
        end
        work = proc do
          process_slot(row, cfg, slot, token: token, now: now)
        rescue StandardError => error
          log(
            :brainstorm_suggestion_worker_error,
            project: row.project, slug: row.slug, ordinal: slot.ordinal,
            error: bounded_error(error)
          )
        ensure
          @mutex.synchronize { @jobs.delete(key) }
        end
        thread = @worker_launcher.call(work)
        @mutex.synchronize { @jobs[key].thread = thread if @jobs.key?(key) }
      rescue StandardError
        @mutex.synchronize { @jobs.delete(key) } if key
        raise
      end

      def process_slot(row, cfg, slot, token:, now:)
        return if token.cancelled?

        bundle = capture(row, cfg, slot)
        input_binding = bound_input(row.folder, slot, bundle)
        attempt = prepare_attempt(row, cfg, slot, input_binding, now: now)
        return unless attempt
        return if token.cancelled?

        runner = @runner_factory.call(cfg, Hive::Task.new(row.folder.to_s).project_root)
        result = runner.call(bundle: bundle, cancellation: token)
        return if token.cancelled?

        observed = capture(row, cfg, slot)
        observed_binding = bound_input(row.folder, slot, observed)
        if observed_binding != input_binding
          result = stale_result("selected_inputs_changed")
        end
        publish_result(
          row, slot, attempt: attempt, input_binding: input_binding,
          result: result, now: @clock.call, cfg: cfg
        )
      rescue Hive::BrainstormSuggestions::ContextBundle::CaptureError => error
        publish_capture_failure(row, slot, error.code, now: @clock.call)
      rescue Hive::ConcurrentRunError
        nil
      end

      def capture(row, cfg, slot)
        timeout = cfg.dig("brainstorm", "suggestions", "capture_timeout_sec").to_f
        @context_factory.call(
          project_root: Hive::Task.new(row.folder.to_s).project_root,
          task_root: row.folder.to_s,
          question_ordinal: slot.ordinal,
          deadline: monotonic_now + timeout
        )
      end

      def bound_input(task_root, slot, bundle)
        Hive::BrainstormSuggestions::Binding.input(
          task_incarnation: task_incarnation(task_root),
          task_generation: task_generation(task_root),
          brainstorm_generation: slot.brainstorm_generation,
          question_identity: slot.question_id,
          question_text: slot.question_text,
          manifest: bundle.manifest,
          settled_answers: bundle.settled_answers
        )
      end

      def prepare_attempt(row, cfg, slot, input_binding, now:)
        task_root = row.folder.to_s
        prepared = nil
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_request", slug: row.slug },
          create: false
        ) do
          return unless current_unanswered_slot(task_root, slot)

          store = Hive::BrainstormSuggestions::Store.new(task_root)
          store.update do |document|
            record = document.fetch("records").find do |candidate|
              candidate["question_id"] == slot.question_id
            end
            next document unless record
            next document unless request_due?(record, input_binding, cfg, now: now)

            same_epoch = record["input_epoch"] == input_binding
            attempts = same_epoch ? record.fetch("automatic_attempts", 0).to_i : 0
            max_attempts = cfg.dig("brainstorm", "suggestions", "max_automatic_attempts").to_i
            if same_epoch && attempts >= max_attempts
              exhausted_record!(record, now: now)
              next document
            end
            next document unless reserve_task_window(task_root, cfg, now: now)

            attempt_id = SecureRandom.uuid
            record.merge!(
              "input_binding" => input_binding,
              "input_epoch" => input_binding,
              "suggestion_binding" => nil,
              "state" => "loading",
              "text" => nil,
              "rationale" => nil,
              "provenance" => [],
              "safe_reason" => nil,
              "retryable" => false,
              "dismissed" => false,
              "attempt_id" => attempt_id,
              "candidate_id" => nil,
              "requested_at" => now.utc.iso8601(6),
              "updated_at" => now.utc.iso8601(6),
              "next_retry_at" => nil,
              "automatic_attempts" => attempts + 1,
              "error_code" => nil
            )
            prepared = { "attempt_id" => attempt_id, "automatic_attempts" => attempts + 1 }
            document["updated_at"] = now.utc.iso8601(6)
            document
          end
        end
        prepared
      end

      def request_due?(record, input_binding, cfg, now:)
        same_epoch = record["input_epoch"] == input_binding
        return true unless same_epoch
        return false if %w[fresh no_safe_suggestion unavailable].include?(record["state"])
        if record["state"] == "loading" && record["attempt_id"]
          requested_at = parse_time(record["requested_at"])
          timeout = cfg.dig("brainstorm", "suggestions", "timeout_sec").to_i
          return false if requested_at && now < requested_at + timeout + ORPHAN_GRACE_SEC
        end
        retry_at = parse_time(record["next_retry_at"])
        !retry_at || now >= retry_at
      end

      def publish_result(row, slot, attempt:, input_binding:, result:, now:, cfg:)
        task_root = row.folder.to_s
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_result", slug: row.slug },
          create: false
        ) do
          return unless current_unanswered_slot(task_root, slot)

          store = Hive::BrainstormSuggestions::Store.new(task_root)
          store.update do |document|
            record = document.fetch("records").find do |candidate|
              candidate["question_id"] == slot.question_id
            end
            return document unless record && record["attempt_id"] == attempt.fetch("attempt_id") &&
                                          record["input_binding"] == input_binding

            apply_result!(record, result, input_binding, attempt, cfg, now: now)
            document["updated_at"] = now.utc.iso8601(6)
            document
          end
        end
      end

      def apply_result!(record, result, input_binding, attempt, cfg, now:)
        state = result.fetch("state")
        candidate_id = state == "fresh" ? SecureRandom.uuid : nil
        suggestion_binding = if candidate_id
          Hive::BrainstormSuggestions::Binding.suggestion(
            input_binding: input_binding,
            attempt_id: attempt.fetch("attempt_id"),
            candidate_id: candidate_id
          )
        end
        record.merge!(
          "suggestion_binding" => suggestion_binding,
          "state" => state,
          "text" => state == "fresh" ? result["text"] : nil,
          "rationale" => state == "fresh" ? result["rationale"] : nil,
          "provenance" => state == "fresh" ? Array(result["provenance"]) : [],
          "safe_reason" => state == "fresh" ? nil : result["safe_reason"],
          "retryable" => result["retryable"] == true,
          "dismissed" => false,
          "candidate_id" => candidate_id,
          "updated_at" => now.utc.iso8601(6),
          "next_retry_at" => next_retry_at(result, attempt, cfg, now: now),
          "error_code" => result["error_code"]
        )
      end

      def publish_capture_failure(row, slot, code, now:)
        task_root = row.folder.to_s
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_capture_failure", slug: row.slug },
          create: false
        ) do
          return unless current_unanswered_slot(task_root, slot)

          store = Hive::BrainstormSuggestions::Store.new(task_root)
          store.update do |document|
            record = document.fetch("records").find do |candidate|
              candidate["question_id"] == slot.question_id
            end
            return document unless record

            record.merge!(
              "suggestion_binding" => nil,
              "state" => "unavailable",
              "text" => nil,
              "rationale" => nil,
              "provenance" => [],
              "safe_reason" => "Repository context could not be captured safely; manual answering remains available.",
              "retryable" => true,
              "dismissed" => false,
              "candidate_id" => nil,
              "updated_at" => now.utc.iso8601(6),
              "next_retry_at" => nil,
              "error_code" => code.to_s[0, 80]
            )
            document["updated_at"] = now.utc.iso8601(6)
            document
          end
        end
      rescue Hive::ConcurrentRunError, SystemCallError, IOError
        nil
      end

      def next_retry_at(result, attempt, cfg, now:)
        if result["state"] == "stale"
          return (now + cfg.dig("brainstorm", "suggestions", "coalesce_window_sec").to_i)
            .utc.iso8601(6)
        end
        return nil unless result["state"] == "failed"

        attempts = attempt.fetch("automatic_attempts")
        max_attempts = cfg.dig("brainstorm", "suggestions", "max_automatic_attempts").to_i
        return nil if attempts >= max_attempts

        configured = cfg.dig("brainstorm", "suggestions", "min_retry_interval_sec").to_i
        interval = [ configured, BACKOFF_SECONDS.fetch([ attempts - 1, BACKOFF_SECONDS.length - 1 ].min) ].max
        jitter = Digest::SHA256.hexdigest(attempt.fetch("attempt_id")).to_i(16) % 31
        (now + interval + jitter).utc.iso8601(6)
      end

      def exhausted_record!(record, now:)
        record.merge!(
          "state" => "failed",
          "text" => nil,
          "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "Automatic suggestion attempts are exhausted; manual Retry remains available.",
          "retryable" => true,
          "suggestion_binding" => nil,
          "candidate_id" => nil,
          "updated_at" => now.utc.iso8601(6),
          "next_retry_at" => nil,
          "error_code" => "automatic_attempts_exhausted"
        )
      end

      def stale_result(code)
        {
          "state" => "stale", "text" => nil, "rationale" => nil,
          "provenance" => [],
          "safe_reason" => "Selected inputs changed; the prior suggestion was discarded.",
          "retryable" => false, "dismissed" => false, "error_code" => code
        }
      end

      def current_unanswered_slot(task_root, slot)
        return false unless brainstorm_task_root?(task_root)

        current = Hive::BrainstormParser.parse(state_path(task_root))[slot.ordinal - 1]
        current && !current.answered? &&
          Hive::BrainstormParser.question_fingerprint(current.text) == slot.question_fingerprint
      end

      def cleanup_row(row)
        return unless row&.folder && File.directory?(row.folder.to_s)

        path = File.join(row.folder.to_s, Hive::BrainstormSuggestions::STORE_FILENAME)
        brainstorm = state_path(row.folder)
        return unless File.exist?(path) || File.symlink?(path) || envelope_present?(brainstorm)

        cleanup_task(row.folder)
      end

      def cleanup_task(task_root)
        cancel_task(task_root)
        Hive::Lock.with_task_lock(
          task_root,
          { op: "brainstorm_suggestion_terminal_cleanup", slug: File.basename(task_root.to_s) },
          create: false
        ) do
          cleanup_envelopes(state_path(task_root))
          Hive::BrainstormSuggestions::Store.new(task_root).delete!
        end
      rescue Hive::ConcurrentRunError, Hive::BrainstormSuggestions::Error,
             SystemCallError, IOError
        false
      end

      def cleanup_envelopes(path)
        return unless File.file?(path)

        Hive::Markers.with_markers_lock(path, create: false, timeout: 1) do
          body = File.read(path, encoding: "UTF-8").scrub
          stripped = Hive::BrainstormSuggestions::Envelope.strip(body).text
          Hive::Markers.write_atomic(path, stripped) unless stripped == body
        end
      end

      def cancel_task(task_root)
        prefix = File.expand_path(task_root.to_s)
        @mutex.synchronize do
          @jobs.each do |(root, _question_id), job|
            job.token.cancel! if root == prefix
          end
          @next_launch_at.delete_if { |(root, _question_id), _value| root == prefix }
          @task_next_launch_at.delete(prefix)
        end
      end

      def cancel_missing(active_roots)
        allowed = active_roots.to_h { |root| [ root, true ] }
        @mutex.synchronize do
          @jobs.each do |(root, _question_id), job|
            job.token.cancel! unless allowed[root]
          end
          @next_launch_at.delete_if { |(root, _question_id), _value| !allowed[root] }
          @task_next_launch_at.delete_if { |root, _value| !allowed[root] }
        end
      end

      def prune_removed_questions(task_root, slots)
        root = File.expand_path(task_root.to_s)
        current_ids = slots.to_h { |slot| [ slot.question_id, true ] }
        @mutex.synchronize do
          @jobs.each do |(job_root, question_id), job|
            job.token.cancel! if job_root == root && !current_ids[question_id]
          end
          @next_launch_at.delete_if do |(job_root, question_id), _value|
            job_root == root && !current_ids[question_id]
          end
        end
      end

      def reserve_task_window(task_root, cfg, now:)
        root = File.expand_path(task_root.to_s)
        @mutex.synchronize do
          next_at = @task_next_launch_at[root]
          return false if next_at && now < next_at

          window = cfg.dig("brainstorm", "suggestions", "coalesce_window_sec").to_i
          @task_next_launch_at[root] = now + window
        end
        true
      end

      def envelope_present?(path)
        File.file?(path) && File.read(path, 256 * 1024).match?(Hive::BrainstormSuggestions::Envelope::RESERVED_RE)
      rescue SystemCallError, IOError
        false
      end

      def brainstorm_task_root?(task_root)
        File.directory?(task_root) && File.basename(File.dirname(task_root)) == STAGE
      end

      def build_runner(cfg, _project_root)
        suggestion_cfg = cfg.dig("brainstorm", "suggestions")
        profile = Hive::AgentProfiles.lookup(suggestion_cfg.fetch("agent"), cfg: cfg)
        routing = Hive::Stages::Base.model_routing_arguments(
          cfg, "brainstorm_suggestion", profile,
          current: Hive::Stages::Base.model_routing_current(suggestion_cfg)
        )
        Hive::BrainstormSuggestions::Runner.new(
          profile: profile,
          model_arguments: routing ? routing.native_arguments : [],
          timeout_sec: suggestion_cfg.fetch("timeout_sec")
        )
      end

      def capture_context(**kwargs)
        Hive::BrainstormSuggestions::ContextBundle.capture(**kwargs)
      end

      def task_incarnation(task_root)
        task = Hive::Task.new(task_root)
        stat = File.stat(task_root)
        Digest::SHA256.hexdigest(
          [ "hive-brainstorm-suggestion-incarnation-v1", task.id, task.slug,
            stat.dev, stat.ino ].join("\0")
        )
      end

      def task_generation(task_root)
        task = Hive::Task.new(task_root)
        Hive::Attempts::Generation.current_task_input_epoch(task)
      rescue Hive::Error, SystemCallError, IOError
        0
      end

      def brainstorm_generation(parsed)
        Hive::BrainstormSuggestions::Binding.digest(
          "questions" => parsed.map do |question|
            {
              "round" => question.round,
              "number" => question.n,
              "text" => question.text,
              "settled_answer" => question.answer
            }
          end
        )
      end

      def question_id(incarnation, fingerprint, ordinal)
        Digest::SHA256.hexdigest(
          [ "hive-brainstorm-suggestion-question-v1", incarnation, fingerprint, ordinal ].join("\0")
        )
      end

      def pending_binding(slot)
        Hive::BrainstormSuggestions::Binding.digest(
          "state" => "pending_capture",
          "question_id" => slot.question_id,
          "brainstorm_generation" => slot.brainstorm_generation
        )
      end

      def slot_identities(slots)
        slots.map { |slot| [ slot.ordinal, slot.question_id, slot.question_fingerprint ] }
      end

      def state_path(task_root)
        File.join(task_root.to_s, "brainstorm.md")
      end

      def parse_time(value)
        Time.iso8601(value.to_s) unless value.to_s.empty?
      rescue ArgumentError
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def bounded_error(error)
        "#{error.class}: #{error.message}".to_s.scrub.byteslice(0, 240)
      end

      def log(event, **payload)
        @logger&.event(event, **payload)
      end
    end
  end
end
