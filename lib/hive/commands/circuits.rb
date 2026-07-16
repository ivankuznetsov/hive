require "json"
require "hive/attempt_lease_store"
require "hive/config"
require "hive/provider_routing/store"

module Hive
  module Commands
    class Circuits
      def initialize(subcommand = nil, provider = nil, model: nil, reason: nil, json: false,
                     store: Hive::ProviderRouting::Store.new,
                     lease_store: Hive::AttemptLeaseStore.new,
                     accounts: nil, actor: nil)
        @subcommand = subcommand.to_s.empty? ? "list" : subcommand.to_s
        @provider = provider&.to_s
        @model = model&.to_s
        @reason = reason&.to_s
        @json = json
        @store = store
        @lease_store = lease_store
        @accounts = accounts
        @actor = actor || "pid:#{Process.pid}"
      end

      def call
        case @subcommand
        when "list" then list
        when "clear" then clear
        else raise Hive::ConfigError, "hive circuits: expected list or clear, got #{@subcommand.inspect}"
        end
      rescue Hive::Error => e
        emit_error(e) if @json
        raise
      end

      private

      def list
        payload = envelope(rows)
        if @json
          puts JSON.generate(payload)
        else
          print_human(payload.fetch("circuits"))
        end
        payload
      end

      def clear
        raise Hive::ConfigError, "hive circuits clear: missing PROVIDER" if @provider.to_s.strip.empty?
        raise Hive::ConfigError, "hive circuits clear: --reason must be non-empty" if @reason.to_s.strip.empty?

        snapshot = @store.snapshot
        entry = snapshot.fetch("providers").fetch(@provider, nil)
        target = @model ? entry&.dig("models", @model) : entry&.fetch("circuit", nil)
        unless target
          suffix = @model ? "/#{@model}" : ""
          raise Hive::ConfigError, "hive circuits clear: unknown circuit #{@provider}#{suffix}"
        end

        transition = @store.clear(
          provider: @provider, model: @model, reason: @reason.strip, actor: @actor
        )
        payload = {
          "schema" => "hive-circuits", "schema_version" => 1, "ok" => true,
          "cleared" => transition_payload(transition)
        }
        @json ? puts(JSON.generate(payload)) : puts("cleared #{@provider}#{@model ? "/#{@model}" : ""}: #{@reason.strip}")
        payload
      end

      def rows
        snapshot = @store.snapshot
        providers = (accounts.keys + snapshot.fetch("providers").keys).uniq.sort
        providers.flat_map do |provider|
          entry = snapshot.dig("providers", provider) || {}
          models = entry.fetch("models", {}).keys.sort
          [ row(provider, nil, entry["circuit"]), *models.map { |model| row(provider, model, entry.dig("models", model)) } ]
        end
      end

      def row(provider, model, state)
        state ||= Hive::ProviderRouting::Circuit.closed
        account = accounts[provider]
        {
          "provider" => provider,
          "model" => model,
          "adapter" => account&.adapter,
          "state" => state.fetch("state"),
          "reason" => state["reason"],
          "retry_at" => state["retry_at"],
          "indefinite" => state.fetch("indefinite", false),
          "probe" => state["probe"],
          "observed_concurrency" => @lease_store.active_count(group: provider),
          "max_concurrent" => account&.max_concurrent,
          "generation" => state.fetch("generation", 0),
          "last_transition_at" => state["last_transition_at"]
        }
      end

      def accounts
        @accounts ||= Hive::Config.load_global_provider_accounts
      end

      def envelope(circuits)
        {
          "schema" => "hive-circuits", "schema_version" => 1, "ok" => true,
          "circuits" => circuits
        }
      end

      def transition_payload(transition)
        {
          "provider" => transition.provider, "model" => transition.model,
          "from" => transition.from, "to" => transition.to,
          "reason" => transition.reason, "generation" => transition.generation,
          "at" => transition.at.utc.iso8601
        }
      end

      def print_human(circuits)
        puts "PROVIDER/MODEL\tADAPTER\tSTATE\tREASON\tRETRY\tCONCURRENCY"
        circuits.each do |item|
          name = [ item.fetch("provider"), item["model"] ].compact.join("/")
          cap = item["max_concurrent"] || "unlimited"
          retry_value = item["indefinite"] ? "manual" : (item["retry_at"] || "-")
          puts [ name, item["adapter"] || "-", item.fetch("state"), item["reason"] || "-",
                 retry_value, "#{item.fetch('observed_concurrency')}/#{cap}" ].join("\t")
        end
      end

      def emit_error(error)
        puts JSON.generate(
          "schema" => "hive-circuits", "schema_version" => 1, "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "message" => error.message
        )
      end
    end
  end
end
