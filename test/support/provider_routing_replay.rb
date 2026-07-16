require "json"
require "hive/agent_profiles"
require "hive/provider_routing/configuration"
require "hive/provider_routing/request"
require "hive/provider_routing/router"

module HiveTestProviderRoutingReplay
  class Replay
    BASE_TIME = Time.utc(2026, 7, 16, 12, 0, 0)

    attr_reader :selections, :decisions, :router, :store, :leases, :accounts

    def initialize(path:, state_home:)
      @records = File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      meta = @records.shift
      raise "provider replay fixture must start with meta" unless meta&.fetch("type", nil) == "meta"

      @now = BASE_TIME
      @accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
        meta.fetch("accounts"), source: path
      )
      @routing = { "pool" => meta.fetch("pool") }
      @store = Hive::ProviderRouting::Store.new(
        path: File.join(state_home, "provider-circuits.v1.json"), clock: -> { @now }
      )
      @leases = Hive::AttemptLeaseStore.new(
        path: File.join(state_home, "attempt-leases.v1.json"), clock: -> { @now }
      )
      @router = Hive::ProviderRouting::Router.new(
        circuit_store: @store, lease_store: @leases, clock: -> { @now }
      )
      @decisions = {}
      @selections = []
    end

    def run
      @records.each do |record|
        @now = BASE_TIME + record.fetch("at")
        send("apply_#{record.fetch('action')}", record)
      end
      self
    ensure
      @decisions.each_value { |decision| @router.cancel(decision, now: @now) if decision.selected? }
    end

    def transition_events
      path = Hive::Paths.provider_circuit_events_path
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
          .select { |event| event["event"] == "circuit_transition" }
    end

    private

    def apply_dispatch(record)
      request = Hive::ProviderRouting::Request.new(
        configuration: configuration(record["routing"] || @routing),
        checkpoint: record.fetch("id"),
        attempt_id: record.fetch("id"),
        provenance: { "fixture" => true }
      )
      decision = @router.select(request)
      @decisions[record.fetch("id")] = decision
      @selections << {
        "id" => record.fetch("id"),
        "status" => decision.status.to_s,
        "provider" => decision.provider,
        "model" => decision.model,
        "probe" => decision.probe?,
        "wait_reason" => decision.wait_reason
      }
      expected = record["expect_provider"]
      raise "expected #{expected}, got #{decision.provider}" if expected && decision.provider != expected
      if record.key?("expect_probe") && decision.probe? != record.fetch("expect_probe")
        raise "probe expectation failed for #{record.fetch('id')}"
      end
    end

    def apply_failure(record)
      decision = @decisions.fetch(record.fetch("id"))
      signal = decision.profile.normalize_error(
        evidence: record.fetch("evidence"), exit_code: 1, timed_out: false,
        model: decision.model, provider: decision.provider,
        evidence_ref: "fixture:#{record.fetch('id')}", success: false
      )
      @router.record_outcome(
        decision: decision, success: false, signal: signal,
        checkpoint: record.fetch("id"), now: @now
      )
      @decisions.delete(record.fetch("id"))
    end

    def apply_success(record)
      decision = @decisions.fetch(record.fetch("id"))
      @router.record_outcome(
        decision: decision, success: true, signal: nil,
        checkpoint: record.fetch("id"), now: @now
      )
      @decisions.delete(record.fetch("id"))
    end

    def configuration(routing)
      Hive::ProviderRouting::Configuration.from(
        cfg: { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => @accounts },
        stage_name: "replay", routing: routing, agent: "claude",
        source: "provider routing replay"
      )
    end
  end
end
