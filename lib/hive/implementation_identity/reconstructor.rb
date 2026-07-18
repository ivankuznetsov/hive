require "json"
require "hive/attempts/context"
require "hive/implementation_identity/resolver"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module ImplementationIdentity
    class Reconstructor
      def initialize(task:, cfg:, attempt_store:, writer: nil, projection_store: nil,
                     resolver: nil)
        @task = task
        @cfg = cfg
        @attempt_store = attempt_store
        @writer = writer || Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: attempt_store
        )
        @projection_store = projection_store || Hive::TaskProjection::Store.new(
          task_folder: task.folder, attempt_store: attempt_store
        )
        @resolver = resolver || Resolver.new(cfg: cfg)
      end

      def reconstruct!
        context = Hive::Attempts::Context.current ||
          raise(ResolutionError, "legacy identity reconstruction requires a durable attempt context")
        projected = @projection_store.read["implementation_identity"]&.dig("execute")
        return selection_from(projected) if projected && projected["generation"] == context.task_generation

        current_attempt = @attempt_store.fetch(context.attempt_id)
        unless current_attempt
          raise ResolutionError, "durable attempt #{context.attempt_id.inspect} is unavailable"
        end
        components, recovery = structured_components(current_attempt) ||
          logged_argv_components(current_attempt) || config_components(context)
        selection = @resolver.resolve_legacy(
          provider: components.fetch("provider"), model: components.fetch("model"),
          effort: components["effort"], generation: context.task_generation,
          attempt_id: components["originating_attempt"] || context.attempt_id
        )
        append_fallback_warning(context) if recovery == :config
        @writer.append_idempotent(
          identity_event(context, selection, recovery),
          idempotency_key: "#{task_key}/#{context.task_generation}/execute-identity"
        )
        @projection_store.rebuild!
        selection
      end

      private

      def structured_components(current_attempt)
        execute_attempts(current_attempt).reverse_each do |attempt|
          data = attempt.to_h
          values = [
            data.dig("checkpoint", "implementation_identity"),
            data.dig("receipt", "final_checkpoint", "implementation_identity"),
            data.dig("diagnostics", "implementation_identity")
          ].compact
          values.each do |identity|
            next unless usable_components?(identity)

            return [ stringify(identity).merge("originating_attempt" => attempt.attempt_id), :structured ]
          end
        end
        nil
      end

      def logged_argv_components(current_attempt)
        log_paths.reverse_each do |path|
          File.readlines(path, chomp: true).reverse_each do |line|
            argv = parse_logged_argv(line)
            next unless argv

            provider = provider_from_argv(argv)
            model = flag_value(argv, "--model", "-m")
            next if provider.nil? || model.to_s.empty?

            effort = flag_value(argv, "--effort", "--reasoning-effort") || codex_effort(argv)
            values = {
              "provider" => provider.to_s,
              "model" => model,
              "effort" => effort,
              "originating_attempt" => execute_attempts(current_attempt).last&.attempt_id
            }
            next unless usable_components?(values)

            return [ values, :logged_argv ]
          end
        rescue SystemCallError
          next
        end
        nil
      end

      def config_components(context)
        fields = Hive::Config.implementation_identity_fields(@cfg, "execute")
        unless fields.key?("agent")
          raise ResolutionError,
                "legacy task has no durable execute identity and execute.agent was not explicitly configured"
        end

        selection = @resolver.resolve_execute(
          generation: context.task_generation, attempt_id: context.attempt_id,
          source: "legacy_backfill"
        )
        [
          {
            "provider" => selection.provider, "model" => selection.model,
            "effort" => selection.requested_effort,
            "originating_attempt" => selection.originating_attempt
          },
          :config
        ]
      end

      def append_fallback_warning(context)
        @writer.append_idempotent(
          base_event(
            context, event_type: "implementation_identity_fallback",
            reason: "legacy_current_config_fallback",
            provenance: { "source" => "legacy_backfill", "warning" => true },
            payload: { "message" => "execute identity recovered from current explicit configuration" }
          ),
          idempotency_key: "#{task_key}/#{context.task_generation}/identity-fallback-warning"
        )
      end

      def identity_event(context, selection, recovery)
        base_event(
          context, event_type: "implementation_identity_backfilled",
          reason: "legacy_identity_#{recovery}",
          provenance: { "source" => "legacy_backfill", "recovery" => recovery.to_s },
          payload: {
            "identity" => selection.to_h.reject { |key, _| key == "native_arguments" }
          }
        )
      end

      def base_event(context, event_type:, reason:, provenance:, payload:)
        attempt = @attempt_store.fetch(context.attempt_id)
        raise ResolutionError, "durable attempt #{context.attempt_id.inspect} is unavailable" unless attempt

        {
          event_type: event_type,
          task: { "id" => task_id, "slug" => @task.slug.to_s },
          workflow: "coding", stage: attempt["intended_stage"],
          attempt_id: context.attempt_id,
          task_generation: context.task_generation,
          ownership_generation: context.ownership_generation,
          commit_generation: 0, reason: reason,
          evidence: [ { "type" => "attempt_lease", "attempt_id" => context.attempt_id } ],
          provenance: provenance, payload: payload
        }
      end

      def selection_from(identity)
        profile = Hive::AgentProfiles.lookup(identity.fetch("provider"), cfg: @cfg)
        arguments = profile.identity_arguments(
          model: identity.fetch("model"), effort: identity["requested_effort"],
          pin_model: identity.fetch("model_pinned", true)
        )
        Selection.new(**identity.slice(*Selection.members.map(&:to_s)).transform_keys(&:to_sym)
                                .merge(native_arguments: arguments.native_arguments))
      end

      def execute_attempts(current_attempt)
        @execute_attempts ||= @attempt_store.scan.records.select do |attempt|
          attempt["task_slug"] == @task.slug.to_s &&
            attempt["project"] == current_attempt["project"] &&
            attempt["task_id"].to_s == current_attempt["task_id"].to_s &&
            attempt.task_input_epoch == current_attempt.task_input_epoch &&
            attempt["intended_stage"] == "4-execute" # coding-scoped: legacy execute reconstruction
        end.sort_by { |attempt| attempt["accepted_at"].to_s }
      end

      def log_paths
        roots = [ File.join(@task.folder, "logs") ]
        roots << @task.log_dir if @task.respond_to?(:log_dir)
        roots.flat_map { |root| Dir.glob(File.join(root, "*.log")) }
             .uniq.sort_by { |path| File.mtime(path) }
      rescue SystemCallError
        []
      end

      def parse_logged_argv(line)
        raw = line[/\bcmd=(\[.*\])\s*\z/, 1]
        return nil unless raw && raw.bytesize <= 32 * 1024

        value = JSON.parse(raw)
        value if value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      rescue JSON::ParserError
        nil
      end

      def provider_from_argv(argv)
        binary = File.basename(argv.first.to_s)
        Hive::AgentProfiles.registered_names.find do |name|
          profile = Hive::AgentProfiles.lookup(name, cfg: @cfg)
          [ File.basename(profile.bin), File.basename(profile.bin_default) ].include?(binary)
        end
      end

      def flag_value(argv, *flags)
        flags.each do |flag|
          index = argv.index(flag)
          return argv[index + 1] if index && argv[index + 1]
        end
        nil
      end

      def codex_effort(argv)
        argv.each_cons(2) do |flag, value|
          next unless flag == "-c"

          match = value.match(/\Amodel_reasoning_effort=([a-z][a-z0-9_-]*)\z/)
          return match[1] if match
        end
        nil
      end

      def usable_components?(values)
        Hive::ImplementationIdentity.normalize_model(values["model"], concrete: true)
        !values["provider"].to_s.empty?
      rescue Hive::ImplementationIdentity::Error
        false
      end

      def stringify(value)
        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def task_key
        task_id ? "id:#{task_id}" : "slug:#{@task.slug}"
      end

      def task_id
        @task.respond_to?(:id) ? @task.id&.to_s : nil
      end
    end
  end
end
