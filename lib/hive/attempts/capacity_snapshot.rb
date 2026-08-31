require "date"
require "forwardable"
require "hive/attempts/repository"

module Hive
  module Attempts
    CapacitySnapshot = Data.define(
      :global_count, :per_project, :per_task, :daily_counts,
      :reserved_attempt_ids
    ) do
      MAX_RESERVATIONS = 1_024
      MAX_DAILY_ATTEMPTS = 10_000

      def self.build(store:, now: Time.now)
        date = now.utc.to_date
        reservations, daily_counts = store.database.read do |db|
          live = db[:capacity_reservations].where(
            Sequel[:capacity_reservations][:state] => "reserved"
          )
            .join(:attempts, attempt_id: :attempt_id)
            .limit(MAX_RESERVATIONS + 1).select_map([
              Sequel[:capacity_reservations][:attempt_id],
              Sequel[:attempts][:project_name], Sequel[:attempts][:task_slug]
            ])
          daily = db[:attempts].where(accepted_date: date.iso8601)
            .join(:attempt_accounting, attempt_id: :attempt_id)
            .where(Sequel[:attempt_accounting][:refunded] => 0)
            .group_and_count(Sequel[:attempts][:project_name]).all
          [ live, daily ]
        end
        raise RepositoryError, "live capacity exceeds its bounded set" if reservations.size > MAX_RESERVATIONS
        raise RepositoryError, "daily accounting exceeds its bounded UTC shard" if
          daily_counts.sum { |row| row.fetch(:count) } > MAX_DAILY_ATTEMPTS

        projects = reservations.map { |_id, project, _slug| project }.tally.freeze
        tasks = reservations.map { |_id, project, slug| [ project, slug ] }.tally.freeze
        new(
          global_count: reservations.size,
          per_project: projects, per_task: tasks,
          daily_counts: daily_counts.to_h do |row|
            [ [ row.fetch(:project_name), date ], row.fetch(:count) ]
          end.freeze,
          reserved_attempt_ids: reservations.map(&:first).freeze
        )
      end

      def project_count(project) = per_project.fetch(project, 0)
      def task_count(project:, task_slug:) = per_task.fetch([ project, task_slug ], 0)
      def daily_count(project, date) = daily_counts.fetch([ project, date ], 0)
      def task_reserved?(project:, task_slug:) = task_count(project: project, task_slug: task_slug).positive?

      def at_limit?(project:, task_slug:, date:, max_global:, max_per_project:, max_daily:)
        global_count >= max_global || project_count(project) >= max_per_project ||
          task_reserved?(project: project, task_slug: task_slug) ||
          daily_count(project, date) >= max_daily
      end

      def self.provider_account_capacity(accounts:, records:, reserved_attempt_ids:)
        read = ->(account, key) { account.respond_to?(key) ? account.public_send(key) : account.fetch(key.to_s) }
        counts = accounts.to_h do |id, account|
          [ id, { "observed" => 0, "max" => Integer(read.call(account, :max_concurrent)) } ]
        end
        defaults = accounts.select { |_id, account| read.call(account, :launch_binding) == "default" }
          .group_by { |_id, account| read.call(account, :adapter) }.transform_values { |values| values.map(&:first) }
        defaults.default = []
        reserved = reserved_attempt_ids.to_h { |id| [ id, true ] }
        Array(records).each do |record|
          next unless reserved[record.attempt_id]
          routing = record["routing"]
          id = if routing.is_a?(Hash) && routing["mode"] == "explicit"
            routing.dig("route", "provider_account_id")
          elsif defaults[record["provider"]].one?
            defaults[record["provider"]].first
          end
          counts[id]["observed"] += 1 if counts.key?(id)
        end
        counts.transform_values!(&:freeze).freeze
      end
    end

    class AdmissionView < Data.define(:store, :records)
      extend Forwardable
      def_delegators :store, :failure_cohort_admission, :claim_failure_cohort_probe,
                     :release_failure_cohort_probe, :record_routing_decision, :routing_decision

      def capacity(now:) = CapacitySnapshot.build(store: store, now: now)

      def find(attempt_id)
        return if attempt_id.to_s.empty?
        store.fetch(attempt_id)
      end

      def terminal_attempt(request_id:) = lookup(:terminal_attempt_id, request_id: request_id)
      def latest_terminal_attempt(**args) = lookup(:latest_terminal_attempt_id, **args)
      def successful_attempt(**args) = lookup(:successful_attempt_id, **args)
      def unresolved_loss(**args) = lookup(:unresolved_loss_attempt_id, **args)
      def successor(**args) = lookup(:successor_attempt_id, **args)

      private

      def lookup(method, **args) = find(store.public_send(method, **args))
    end
  end
end
