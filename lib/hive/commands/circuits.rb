require "etc"
require "json"
require "hive/attempts/store"
require "hive/config"
require "hive/provider_health"
require "hive/provider_routing/operational_projection"
require "hive/terminal_text"

module Hive
  module Commands
    # Explicit, approval-requiring provider-circuit administration. The
    # command can inspect the shared typed projection or submit one scoped
    # generation-CAS mutation; it has no task/recovery collaborators.
    class Circuits
      include Hive::Schemas::EnvelopeEmitter

      ACTIONS = %w[list inspect block unblock reset reset-intent].freeze
      MUTATIONS = %w[block unblock reset reset-intent].freeze

      class UsageError < Hive::Error
        attr_reader :error_kind

        def initialize(message, error_kind: "usage")
          super(message)
          @error_kind = error_kind
        end

        def exit_code = Hive::ExitCodes::USAGE
      end

      def initialize(action = "list", provider: nil, model: nil, reason: nil,
                     expected_generation: nil, journal_epoch: nil,
                     corruption_fingerprint: nil, last_verified_generation: nil,
                     intent_file: nil, yes: false, json: false, accounts: nil, health_store: nil,
                     attempt_store: nil, actor_resolver: nil, clock: -> { Time.now.utc })
        @action = action.to_s
        @provider = provider
        @model = model
        @reason = reason
        @expected_generation = expected_generation
        @journal_epoch = journal_epoch
        @corruption_fingerprint = corruption_fingerprint
        @last_verified_generation = last_verified_generation
        @intent_file = intent_file
        @yes = yes
        @json = json
        @accounts = accounts
        @health_store = health_store
        @attempt_store = attempt_store
        @actor_resolver = actor_resolver || method(:trusted_actor)
        @clock = clock
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-circuits"

      def envelope_error_kind(error)
        case error
        when UsageError then error.error_kind
        when Hive::ProviderHealth::StaleGeneration then "stale_generation"
        when Hive::ProviderHealth::InvalidMutation, Hive::ProviderHealth::InvalidScope
          "usage"
        when Hive::ProviderHealth::Unavailable, Hive::Attempts::StoreError
          "unavailable"
        when Hive::ConfigError then "config"
        else "internal"
        end
      end

      private

      def do_call
        validate_action!
        mutation = mutate if MUTATIONS.include?(@action)
        intent_state = health_store.inspect_probe_intents
        projection = Hive::ProviderRouting::OperationalProjection.new(
          accounts: filtered_accounts,
          health_store: health_store,
          attempt_store: attempt_store,
          now: now
        ).to_h
        payload = success_payload(projection, mutation, intent_state)
        if @json
          puts JSON.generate(payload)
          @stdout_written = true
        else
          render(payload)
        end
      end

      def validate_action!
        return if ACTIONS.include?(@action)

        raise UsageError,
              "hive circuits: unknown action #{@action.inspect} (expected: #{ACTIONS.join(', ')})"
      end

      def mutate
        unless @yes
          raise UsageError.new(
            "hive circuits #{@action}: explicit approval required; inspect first, then pass --yes",
            error_kind: "consent_required"
          )
        end
        if @reason.nil? || @reason.to_s.strip.empty?
          raise UsageError, "hive circuits #{@action}: --reason is required"
        end

        return reset_probe_intent if @action == "reset-intent"

        reject_intent_options!
        scope = selected_scope
        result = case @action
        when "block"
          reject_corruption_options!
          health_store.block(
            scope: scope,
            expected_generation: required_generation,
            actor: @actor_resolver.call,
            reason: @reason
          )
        when "unblock"
          reject_corruption_options!
          health_store.unblock(
            scope: scope,
            expected_generation: required_generation,
            actor: @actor_resolver.call,
            reason: @reason
          )
        when "reset"
          reset_scope(scope)
        end
        {
          "action" => @action,
          "status" => result.status,
          "reason" => result.reason,
          "target" => scope.to_h,
          "generation" => result.generation,
          "event_id" => result.event_id,
          "audit" => result.audit_receipt&.to_h
        }
      end

      def reset_probe_intent
        if [ @provider, @model, @expected_generation, @journal_epoch,
             @last_verified_generation ].any?
          raise UsageError,
                "hive circuits reset-intent: use only --intent-file, " \
                "--corruption-fingerprint, --reason, and --yes"
        end
        if @intent_file.nil? || @intent_file.to_s.strip.empty? || @corruption_fingerprint.nil?
          raise UsageError,
                "hive circuits reset-intent: --intent-file and " \
                "--corruption-fingerprint are required"
        end

        result = health_store.reset_probe_intent(
          intent_file: @intent_file,
          corruption_fingerprint: @corruption_fingerprint,
          actor: @actor_resolver.call,
          reason: @reason
        )
        {
          "action" => "reset_intent",
          "status" => result.fetch("status"),
          "reason" => result.fetch("reason"),
          "target" => {
            "kind" => "probe_intent",
            "intent_file" => result.fetch("intent_file")
          },
          "generation" => nil,
          "event_id" => result.fetch("event_id"),
          "audit" => result.fetch("audit")
        }
      end

      def reset_scope(scope)
        token_fields = [ @journal_epoch, @corruption_fingerprint, @last_verified_generation ]
        if token_fields.any?
          unless token_fields.all? && @expected_generation.nil?
            raise UsageError,
                  "hive circuits reset: supply the complete corruption token without --expected-generation"
          end
          token = Hive::ProviderHealth::CorruptionToken.new(
            scope: scope,
            journal_epoch: integer_option(@journal_epoch, "--journal-epoch"),
            corruption_fingerprint: @corruption_fingerprint,
            last_verified_generation: integer_option(
              @last_verified_generation, "--last-verified-generation"
            )
          )
          return health_store.reset(
            scope: scope,
            corruption_token: token,
            actor: @actor_resolver.call,
            reason: @reason
          )
        end

        health_store.reset(
          scope: scope,
          expected_generation: required_generation,
          actor: @actor_resolver.call,
          reason: @reason
        )
      end

      def reject_corruption_options!
        return unless [ @journal_epoch, @corruption_fingerprint, @last_verified_generation ].any?

        raise UsageError, "corruption-token options are valid only for hive circuits reset"
      end

      def reject_intent_options!
        return if @intent_file.nil?

        raise UsageError, "--intent-file is valid only for hive circuits reset-intent"
      end

      def required_generation
        if @expected_generation.nil?
          raise UsageError, "hive circuits #{@action}: --expected-generation is required"
        end

        integer_option(@expected_generation, "--expected-generation")
      end

      def selected_scope
        account = selected_account
        return Hive::ProviderHealth::Scope.provider_account(account_id: account.id) if @model.nil?

        model = @model.to_s
        unless account.models.include?(model)
          raise UsageError, "hive circuits: model #{model.inspect} is not configured for #{@provider.inspect}"
        end
        Hive::ProviderHealth::Scope.model(account_id: account.id, model_id: model)
      end

      def selected_account
        if @provider.nil? || @provider.to_s.strip.empty?
          raise UsageError, "hive circuits #{@action}: --provider is required"
        end
        account = accounts[@provider.to_s]
        return account if account

        raise UsageError, "hive circuits: unknown provider account #{@provider.inspect}"
      end

      def filtered_accounts
        if @provider.nil? && !@model.nil?
          raise UsageError, "hive circuits: --model requires --provider"
        end
        return accounts if @provider.nil?

        account = selected_account
        return { account.id => account }.freeze if @model.nil?

        model = @model.to_s
        unless account.models.include?(model)
          raise UsageError, "hive circuits: model #{model.inspect} is not configured for #{@provider.inspect}"
        end
        selected = Hive::ProviderRouting::Account.new(
          id: account.id,
          adapter: account.adapter,
          launch_binding: account.launch_binding,
          models: [ model ],
          max_concurrent: account.max_concurrent,
          cooldown_sec: account.cooldown_sec
        )
        { selected.id => selected }.freeze
      end

      def success_payload(projection, mutation, intent_state)
        corruptions = intent_state.fetch("corruptions")
        issues = projection.fetch("issues").dup
        unless corruptions.empty?
          issues << "provider-health probe intent state is unavailable " \
                    "(#{corruptions.length} corrupt artifact#{'s' unless corruptions.length == 1})"
        end
        {
          "schema" => "hive-circuits",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-circuits"),
          "ok" => true,
          "generated_at" => projection.fetch("generated_at"),
          "status" => corruptions.empty? ? projection.fetch("status") : "degraded",
          "issues" => issues.freeze,
          "accounts" => projection.fetch("accounts"),
          "decisions" => projection.fetch("decisions"),
          "intent_corruptions" => corruptions,
          "mutation" => mutation
        }
      end

      def render(payload)
        puts "PROVIDER CIRCUITS #{payload.fetch('status').upcase} — " \
             "#{payload.fetch('accounts').length} accounts · " \
             "#{payload.fetch('decisions').length} recent decisions"
        payload.fetch("issues").each { |issue| puts "  ! #{safe(issue)}" }
        payload.fetch("intent_corruptions").each do |corruption|
          puts "  ! probe-intent #{safe(corruption.fetch('intent_file'))} " \
               "repair_fingerprint=#{safe(corruption.fetch('corruption_fingerprint'))}"
        end
        payload.fetch("accounts").each { |account| render_account(account) }
        payload.fetch("decisions").each { |entry| render_decision(entry) }
        render_mutation(payload.fetch("mutation")) if payload["mutation"]
      end

      def render_account(account)
        capacity = account.fetch("capacity")
        puts "#{safe(account.fetch('provider_account_id'))} " \
             "(#{safe(account.fetch('adapter'))}, capacity " \
             "#{capacity.fetch('observed')}/#{capacity.fetch('max')})"
        puts "  provider #{circuit_summary(account.fetch('circuit'))}"
        account.fetch("models").each do |model|
          puts "  #{safe(model.fetch('model'))} #{circuit_summary(model.fetch('circuit'))}"
        end
      end

      def circuit_summary(circuit)
        summary = "#{safe(circuit.fetch('state'))} gen=#{circuit.fetch('generation')} " \
                  "epoch=#{circuit.fetch('journal_epoch')}"
        summary += " eligible_at=#{safe(circuit['eligible_at'])}" if circuit["eligible_at"]
        summary += " reason=#{safe(circuit['reason'])}" if circuit["reason"]
        if (probe = circuit["probe_owner"])
          summary += " probe=#{safe(probe['attempt_id'])}@#{probe['claim_generation']}"
        end
        if (evidence = circuit["evidence"])
          summary += " evidence=#{safe(evidence['failure_class'])}:#{safe(evidence['fingerprint'])}"
          summary += " ref=#{safe(evidence.dig('source_reference', 'path'))}"
        end
        if (token = circuit["corruption_token"])
          summary += " repair_epoch=#{token.fetch('journal_epoch')} " \
                     "repair_fingerprint=#{token.fetch('corruption_fingerprint')} " \
                     "repair_last_verified_generation=" \
                     "#{token.fetch('last_verified_generation')}"
        end
        summary
      end

      def render_decision(entry)
        identity = entry.fetch("identity")
        decision = entry.fetch("decision")
        selected = decision["selected_route"] || "none"
        puts "decision #{safe(decision.fetch('decision_id'))} " \
             "#{safe(identity.fetch('project'))}/#{safe(identity.fetch('task_slug'))} " \
             "status=#{safe(decision.fetch('status'))} reason=#{safe(decision.fetch('reason'))} " \
             "owner=#{safe(decision.fetch('next_action_owner'))} selected=#{safe(selected)}"
        puts "  policy=#{safe(decision.fetch('policy_digest'))} " \
             "task_generation=#{safe(decision.fetch('task_generation'))} " \
             "pin=#{safe(decision.dig('policy', 'pin') || 'none')} " \
             "required=#{safe(JSON.generate(decision.dig('policy', 'requirements')))}"
        decision.fetch("candidates").each do |candidate|
          capacity = candidate["capacity"]
          capacity_text = capacity ? "#{capacity.fetch('observed')}/#{capacity.fetch('max')}" : "n/a"
          exclusions = candidate.fetch("exclusions").map do |exclusion|
            scope = exclusion["scope"]
            scope_text = scope && [ scope["provider_account_id"], scope["model"] ].compact.join("/")
            [ exclusion.fetch("reason"), scope_text ].compact.join("@")
          end
          puts "  candidate #{safe(candidate.fetch('route_id'))} " \
               "eligible=#{candidate.fetch('eligible')} capacity=#{capacity_text} " \
               "exclusions=#{safe(exclusions.empty? ? 'none' : exclusions.join(','))}"
        end
      end

      def render_mutation(mutation)
        generation = mutation["generation"]
        generation_text = generation.nil? ? "n/a" : generation
        puts "MUTATION #{safe(mutation.fetch('action'))} #{safe(mutation.fetch('status'))} " \
             "generation=#{generation_text} event=#{safe(mutation.fetch('event_id'))}"
      end

      def safe(value)
        Hive::TerminalText.escape(value.to_s)
      end

      def trusted_actor
        user = Etc.getpwuid(Process.uid).name
        Hive::ProviderHealth::Audit.validate_actor("uid:#{Process.uid}:#{user}")
      rescue ArgumentError
        Hive::ProviderHealth::Audit.validate_actor("uid:#{Process.uid}")
      end

      def accounts
        @accounts ||= Hive::Config.load_global_provider_accounts
      end

      def health_store
        @health_store ||= Hive::ProviderHealth.open
      end

      def attempt_store
        @attempt_store ||= Hive::Attempts::Store.open_default
      end

      def now = @clock.call.utc

      def integer_option(value, label)
        unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
          raise UsageError, "hive circuits #{@action}: #{label} must be a non-negative integer"
        end

        parsed = Integer(value)
        unless parsed >= 0
          raise UsageError, "hive circuits #{@action}: #{label} must be a non-negative integer"
        end

        parsed
      end
    end
  end
end
