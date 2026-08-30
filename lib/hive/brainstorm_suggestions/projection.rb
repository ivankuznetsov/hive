# frozen_string_literal: true

require "digest"
require "thread"
require "hive/attempts/generation"
require "hive/brainstorm_suggestions/binding"
require "hive/brainstorm_suggestions/context_bundle"
require "hive/brainstorm_suggestions/store"
require "hive/config"
require "hive/task"

module Hive
  module BrainstormSuggestions
    # Produces the single fail-closed read contract shared by CLI and Web.
    # A task is observed once regardless of its number of questions. Cached
    # results are keyed by the task/sidecar lifecycle identity. Repository and
    # wiki capture happens only on cache misses, never as a read-side key scan.
    class Projection
      MAX_OBSERVATION_SECONDS = 2.0
      CACHE_LIMIT = 64
      STALE_REASON = "Suggestion inputs changed; a replacement is being prepared."
      UNAVAILABLE_REASON = "Suggestion freshness could not be verified; answer manually or retry."

      Observation = Data.define(:bindings, :error_code)

      # Small process-local LRU. It stores only bindings and bounded error
      # codes, never repository content or provider output.
      class Cache
        def initialize(limit: CACHE_LIMIT)
          @limit = Integer(limit)
          @entries = {}
          @inflight = {}
          @mutex = Mutex.new
        end

        def fetch(key, cache_if: ->(_value) { true })
          owner = false
          loop do
            @mutex.synchronize do
              if @entries.key?(key)
                value = @entries.delete(key)
                @entries[key] = value
                return value
              end

              if (condition = @inflight[key])
                condition.wait(@mutex)
              else
                @inflight[key] = ConditionVariable.new
                owner = true
              end
            end
            break if owner
          end

          completed = false
          value = yield
          @mutex.synchronize do
            if cache_if.call(value)
              @entries.delete(key)
              @entries[key] = value
              @entries.shift while @entries.length > @limit
            end
            @inflight.delete(key)&.broadcast
            completed = true
          end
          value
        ensure
          if owner && !completed
            @mutex.synchronize { @inflight.delete(key)&.broadcast }
          end
        end

        def clear
          @mutex.synchronize { @entries.clear }
        end
      end

      # One controller-owned observation may capture multiple question-bound
      # bundles, but consumers invoke this seam exactly once per task render.
      class Observer
        def initialize(context_factory: nil)
          @context_factory = context_factory || Hive::BrainstormSuggestions::ContextBundle.method(:capture)
        end

        def call(project_root:, task_root:, questions:, records:, document:, deadline:)
          bundles = if @context_factory.respond_to?(:name) && @context_factory.name == :capture
            Hive::BrainstormSuggestions::ContextBundle.capture_many(
              project_root: project_root, task_root: task_root,
              question_ordinals: records.map { |record| record.fetch("ordinal") },
              deadline: deadline
            )
          else
            records.to_h do |record|
              ordinal = record.fetch("ordinal")
              [ ordinal, @context_factory.call(
                project_root: project_root, task_root: task_root,
                question_ordinal: ordinal, deadline: deadline
              ) ]
            end
          end
          bindings = records.to_h do |record|
            ordinal = record.fetch("ordinal")
            question = questions.fetch(ordinal - 1)
            bundle = bundles.fetch(ordinal)
            binding = Hive::BrainstormSuggestions::Binding.input(
              task_incarnation: document.fetch("task_incarnation"),
              task_generation: document.fetch("task_generation"),
              brainstorm_generation: document.fetch("brainstorm_generation"),
              question_identity: record.fetch("question_id"),
              question_text: question.text,
              manifest: bundle.manifest,
              settled_answers: bundle.settled_answers
            )
            [ ordinal, binding ]
          end
          Observation.new(bindings: bindings.freeze, error_code: nil)
        rescue Hive::BrainstormSuggestions::ContextBundle::CaptureError => error
          Observation.new(bindings: {}.freeze, error_code: error.code)
        rescue KeyError, IndexError, SystemCallError, IOError, ArgumentError
          Observation.new(bindings: {}.freeze, error_code: "observation_unavailable")
        end
      end

      class << self
        def call(**arguments)
          new(**arguments).call
        end

        def cache
          @cache ||= Cache.new
        end

        def clear_cache!
          cache.clear
        end
      end

      def initialize(task_root:, project_root:, questions:, task_generation:,
                     observer: nil, cache: nil, identity_factory: nil,
                     deadline: nil, enabled: nil)
        @task_root = File.expand_path(task_root)
        @project_root = File.expand_path(project_root)
        @questions = Array(questions)
        @task_generation = task_generation.to_s
        @observer = observer || Observer.new
        @cache = cache || self.class.cache
        @identity_factory = identity_factory || method(:observation_identity)
        @deadline = deadline || monotonic_now + MAX_OBSERVATION_SECONDS
        @enabled = enabled
      end

      def call
        return {}.freeze unless feature_enabled?

        document = Hive::BrainstormSuggestions::Store.new(@task_root).read
        return all_unavailable if document["corrupt"]

        records = relevant_records(document)
        result = base_projection(records)
        observable = observable_records(records)
        return result.freeze if observable.empty?
        return replace_observable(result, observable, :stale) unless document_current?(document)

        identity = @identity_factory.call(document, observable, @deadline)
        observation = @cache.fetch(identity, cache_if: ->(value) { value.error_code.nil? }) do
          @observer.call(
            project_root: @project_root,
            task_root: @task_root,
            questions: @questions,
            records: observable,
            document: document,
            deadline: @deadline
          )
        end
        return replace_observable(result, observable, :unavailable) if observation.error_code

        observable.each do |record|
          ordinal = record.fetch("ordinal")
          unless observation.bindings[ordinal] == record["input_binding"]
            result[ordinal] = stale_projection(record)
          end
        end
        result.freeze
      rescue SystemCallError, IOError, Hive::BrainstormSuggestions::Error, ArgumentError
        all_unavailable
      end

      private

      def feature_enabled?
        return @enabled unless @enabled.nil?

        Hive::Config.load(@project_root).dig("brainstorm", "suggestions", "enabled") == true
      rescue Hive::Error, SystemCallError, IOError, ArgumentError
        false
      end

      def relevant_records(document)
        records = document.fetch("records", [])
        @questions.each_with_index.filter_map do |question, index|
          next if question.answered?

          ordinal = index + 1
          record = records.find { |candidate| candidate["ordinal"] == ordinal }
          next unless record
          next unless record["question_fingerprint"] ==
                      Hive::BrainstormParser.question_fingerprint(question.text)

          record
        end
      end

      def base_projection(records)
        by_ordinal = records.to_h { |record| [ record.fetch("ordinal"), record ] }
        @questions.each_with_index.filter_map do |question, index|
          next if question.answered?

          ordinal = index + 1
          record = by_ordinal[ordinal]
          [ ordinal, record ? record_projection(record) : missing_projection ]
        end.to_h
      end

      def observable_records(records)
        records.select do |record|
          record["input_epoch"].to_s.match?(/\A[0-9a-f]{64}\z/)
        end
      end

      def document_current?(document)
        document["recipe_version"] == Hive::BrainstormSuggestions::ContextBundle::RECIPE_VERSION &&
          document["task_incarnation"] == current_task_incarnation &&
          document["task_generation"] == current_task_generation &&
          document["brainstorm_generation"] == current_brainstorm_generation
      end

      def current_task_generation
        Hive::Attempts::Generation.current_task_input_epoch(Hive::Task.new(@task_root))
      rescue Hive::Error, SystemCallError, IOError
        nil
      end

      def current_task_incarnation
        task = Hive::Task.new(@task_root)
        status = File.stat(@task_root)
        Digest::SHA256.hexdigest(
          [ "hive-brainstorm-suggestion-incarnation-v1", task.id, task.slug,
            status.dev, status.ino ].join("\0")
        )
      rescue Hive::Error, SystemCallError, IOError
        nil
      end

      def current_brainstorm_generation
        Hive::BrainstormSuggestions::Binding.digest(
          "questions" => @questions.map do |question|
            {
              "round" => question.respond_to?(:round) ? question.round : nil,
              "number" => question.respond_to?(:n) ? question.n : nil,
              "text" => question.text,
              "settled_answer" => question.answer
            }
          end
        )
      end

      def record_projection(record)
        fresh = record["state"] == "fresh" && record["dismissed"] != true && fully_bound?(record)
        {
          "state" => fresh || record["state"] != "fresh" ? record.fetch("state") : "unavailable",
          "text" => fresh ? record["text"] : nil,
          "rationale" => fresh ? record["rationale"] : nil,
          "provenance" => fresh ? Array(record["provenance"]).dup.freeze : [].freeze,
          "safe_reason" => fresh ? nil : (record["safe_reason"] || UNAVAILABLE_REASON),
          "retryable" => retryable?(record),
          "dismissed" => record["dismissed"] == true,
          "input_binding" => record["input_binding"],
          "suggestion_binding" => record["suggestion_binding"]
        }.freeze
      end

      def fully_bound?(record)
        %w[input_binding input_epoch suggestion_binding].all? do |key|
          record[key].to_s.match?(/\A[0-9a-f]{64}\z/)
        end
      end

      def missing_projection
        {
          "state" => "loading", "text" => nil, "rationale" => nil,
          "provenance" => [].freeze, "safe_reason" => nil,
          "retryable" => false, "dismissed" => false,
          "input_binding" => nil, "suggestion_binding" => nil
        }.freeze
      end

      def stale_projection(record)
        inert_projection(record, state: "stale", reason: STALE_REASON, retryable: false)
      end

      def unavailable_projection(record = nil)
        inert_projection(record, state: "unavailable", reason: UNAVAILABLE_REASON, retryable: true)
      end

      def inert_projection(record, state:, reason:, retryable:)
        {
          "state" => state, "text" => nil, "rationale" => nil,
          "provenance" => [].freeze, "safe_reason" => reason,
          "retryable" => retryable, "dismissed" => false,
          "input_binding" => record&.dig("input_binding"),
          "suggestion_binding" => record&.dig("suggestion_binding")
        }.freeze
      end

      def retryable?(record)
        record["retryable"] == true || record["state"] == "stale" ||
          record["state"] == "fresh" ||
          Hive::BrainstormSuggestions::RETRYABLE_STATES.include?(record["state"])
      end

      def replace_observable(result, records, replacement)
        records.each do |record|
          result[record.fetch("ordinal")] = if replacement == :stale
            stale_projection(record)
          else
            unavailable_projection(record)
          end
        end
        result.freeze
      end

      def all_unavailable
        @questions.each_with_index.filter_map do |question, index|
          next if question.answered?

          [ index + 1, unavailable_projection ]
        end.to_h.freeze
      end

      def observation_identity(document, records, _deadline)
        Hive::BrainstormSuggestions::Binding.digest(
          "recipe" => Hive::BrainstormSuggestions::ContextBundle::RECIPE,
          "recipe_version" => Hive::BrainstormSuggestions::ContextBundle::RECIPE_VERSION,
          "task_generation" => @task_generation,
          "sidecar_generation" => document.slice(
            "task_incarnation", "task_generation", "brainstorm_generation"
          ),
          "questions" => records.map do |record|
            record.slice(
              "ordinal", "question_fingerprint", "input_binding", "suggestion_binding",
              "state", "retryable", "dismissed", "attempt_id", "candidate_id", "updated_at"
            )
          end
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
