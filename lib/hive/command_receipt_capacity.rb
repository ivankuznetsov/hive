# frozen_string_literal: true

require "digest"
require "sqlite3"
require "hive/config"
require "hive/errors"
require "hive/runtime_control_plane/codec"

module Hive
  class CommandReceiptCapacity
    DEFAULT_INSTALLATION_NONTERMINAL_LIMIT = 100_000
    DEFAULT_INSTALLATION_CONCURRENCY_LIMIT = 3_200
    DEFAULT_INSTALLATION_BYTE_LIMIT = 6_710_886_400
    # Measured maximum-payload finalization grew the main file by 225,280
    # bytes and WAL by 255,472 bytes. Round their combined 480,752-byte
    # physical delta up to 512 KiB for the conservative next-operation check.
    NEXT_OPERATION_ALLOWANCE = 512 * 1024
    INSTALLATION_KEYS = %w[
      installation_nonterminal_limit installation_concurrency_limit
      installation_byte_admission_limit
    ].freeze

    Policy = Data.define(
      :keyed_intake_enabled, :nonterminal_limit, :concurrency_limit,
      :byte_admission_limit, :installation_nonterminal_limit,
      :installation_concurrency_limit, :installation_byte_admission_limit,
      :revision, :staffing
    )

    def self.load(project_root)
      _path, raw_project = Hive::Config.read_project_config(project_root)
      raw_receipts = raw_project.fetch("command_receipts", {})
      forbidden = raw_receipts.keys.map(&:to_s) & INSTALLATION_KEYS
      unless forbidden.empty?
        raise Hive::ConfigError,
              "project command_receipts cannot override installation backstops: #{forbidden.sort.join(', ')}"
      end

      project = Hive::Config.load(project_root).fetch("command_receipts")
      global = global_receipts
      installation_nonterminal = positive_integer(
        global.fetch("installation_nonterminal_limit", DEFAULT_INSTALLATION_NONTERMINAL_LIMIT),
        "command_receipts.installation_nonterminal_limit"
      )
      installation_concurrency = positive_integer(
        global.fetch("installation_concurrency_limit", DEFAULT_INSTALLATION_CONCURRENCY_LIMIT),
        "command_receipts.installation_concurrency_limit"
      )
      installation_bytes = positive_integer(
        global.fetch("installation_byte_admission_limit", DEFAULT_INSTALLATION_BYTE_LIMIT),
        "command_receipts.installation_byte_admission_limit"
      )
      canonical = {
        "project" => project,
        "installation" => {
          "nonterminal" => installation_nonterminal,
          "concurrency" => installation_concurrency,
          "bytes" => installation_bytes
        }
      }
      Policy.new(
        keyed_intake_enabled: project.fetch("keyed_intake_enabled"),
        nonterminal_limit: project.fetch("nonterminal_limit"),
        concurrency_limit: project.fetch("concurrency_limit"),
        byte_admission_limit: project.fetch("byte_admission_limit"),
        installation_nonterminal_limit: installation_nonterminal,
        installation_concurrency_limit: installation_concurrency,
        installation_byte_admission_limit: installation_bytes,
        revision: Digest::SHA256.hexdigest(Hive::RuntimeControlPlane::Codec.dump_json(canonical)),
        staffing: project.fetch("staffing")
      )
    end

    def self.global_receipts
      path = Hive::Config.global_config_path
      return {} unless File.exist?(path)
      data = Hive::Config.load_global_config(path)
      raise Hive::ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)
      value = data.fetch("command_receipts", {})
      unless value.is_a?(Hash)
        raise Hive::ConfigError, "command_receipts in global config must be a Hash"
      end
      allowed = INSTALLATION_KEYS + [ "staffing" ]
      unknown = value.keys.map(&:to_s) - allowed
      unless unknown.empty?
        raise Hive::ConfigError,
              "global command_receipts has unknown field(s): #{unknown.sort.join(', ')}"
      end
      value
    end

    def self.positive_integer(value, label)
      return value if value.is_a?(Integer) && value.positive?
      raise Hive::ConfigError, "#{label} must be a positive integer"
    end
    private_class_method :positive_integer

    def self.settlement_budget(staffing:, settlement_minutes:)
      duration = Float(settlement_minutes)
      unless duration.positive? && duration.finite?
        raise Hive::ConfigError, "settlement_minutes must be a positive finite number"
      end
      allocated = staffing.fetch("minutes_per_namespace_per_day", nil)
      return { allocated_minutes: nil, settlement_minutes: duration, daily_ceiling: nil } if allocated.nil?
      minutes = Float(allocated)
      unless minutes >= 0 && minutes.finite?
        raise Hive::ConfigError,
              "command_receipts.staffing.minutes_per_namespace_per_day must be nonnegative"
      end
      {
        allocated_minutes: minutes,
        settlement_minutes: duration,
        daily_ceiling: (minutes / duration).floor
      }
    rescue ArgumentError, TypeError
      raise Hive::ConfigError, "settlement capacity inputs must be numeric"
    end

    def initialize(database:, policy:)
      @database = database
      @policy = policy
    end

    attr_reader :database, :policy

    def admit_nonterminal!(connection, namespace_id:, request_bytes:,
                           occupied_installation_bytes:)
      namespace = connection[:command_capacity][namespace_id: namespace_id]
      totals = connection[:command_capacity].select do
        [ sum(:nonterminal_count).as(:nonterminal), sum(:executing_count).as(:executing) ]
      end.first
      if namespace.fetch(:nonterminal_count) >= policy.nonterminal_limit
        capacity_error!(:command_nonterminal_limit, :namespace, nonterminal_remedy(:namespace))
      end
      if totals.fetch(:nonterminal).to_i >= policy.installation_nonterminal_limit
        capacity_error!(:command_nonterminal_limit, :installation, nonterminal_remedy(:installation))
      end
      allowance = request_bytes + NEXT_OPERATION_ALLOWANCE
      if namespace.fetch(:logical_bytes) + allowance > policy.byte_admission_limit
        capacity_error!(:command_capacity_exhausted, :namespace, byte_remedy(:namespace))
      end
      if occupied_installation_bytes + allowance > policy.installation_byte_admission_limit
        capacity_error!(:command_capacity_exhausted, :installation, byte_remedy(:installation))
      end
      true
    end

    def admit_execution!(connection, namespace_id:)
      namespace = connection[:command_capacity][namespace_id: namespace_id]
      totals = connection[:command_capacity].sum(:executing_count).to_i
      if namespace.fetch(:executing_count) >= policy.concurrency_limit
        capacity_error!(:command_concurrency_limit, :namespace, concurrency_remedy(:namespace))
      end
      if totals >= policy.installation_concurrency_limit
        capacity_error!(:command_concurrency_limit, :installation, concurrency_remedy(:installation))
      end
      true
    end

    # Admission passes its active transaction connection so page/freelist and
    # WAL bytes are observed in the same atomic threshold decision.
    def occupied_installation_bytes(connection: nil)
      measure = lambda do |active_connection|
        page_size = pragma_integer(active_connection, "page_size")
        occupied_pages = pragma_integer(active_connection, "page_count") -
          pragma_integer(active_connection, "freelist_count")
        occupied_main = occupied_pages * page_size
        wal = begin
          File.stat("#{database.path}-wal").size
        rescue Errno::ENOENT
          0
        end
        occupied_main + wal
      end
      connection ? measure.call(connection) : database.read { |db| measure.call(db) }
    rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError, ArgumentError, TypeError
      capacity_error!(
        :command_capacity_exhausted, :installation,
        "free disk and restore runtime database availability, then rerun"
      )
    end

    def pragma_integer(connection, name)
      Integer(connection.fetch("PRAGMA #{name}").first.values.first)
    end

    private :pragma_integer

    private

    def capacity_error!(reason, scope, remedy)
      raise Hive::CommandCapacityError.new(
        "#{reason.to_s.tr('_', ' ')} at #{scope} scope; #{remedy}",
        reason: reason, scope: scope
      )
    end

    def nonterminal_remedy(scope)
      config = scope == :namespace ? "command_receipts.nonterminal_limit" :
        "command_receipts.installation_nonterminal_limit"
      "raise #{config} with matching installation/byte headroom; terminal-only prune reclaims " \
        "pages but does not reduce N; preview IDs with `hive receipt prune --namespace-id UUID --json`; " \
        "settle one receipt using `hive receipt retire RECEIPT_ID --expected-generation G " \
        "--settle-without-result --reason TEXT` and then --confirm; use `hive receipt abandon-batch` " \
        "for stranded maintenance"
    end

    def concurrency_remedy(scope)
      config = scope == :namespace ? "command_receipts.concurrency_limit" :
        "command_receipts.installation_concurrency_limit"
      "raise #{config} for the next admission or confirm `hive receipt retire --orphaned-owner` " \
        "for an owner proven dead"
    end

    def byte_remedy(scope)
      config = scope == :namespace ? "command_receipts.byte_admission_limit" :
        "command_receipts.installation_byte_admission_limit"
      "free disk, run terminal-only prune for reusable pages, provision published storage headroom, " \
        "raise #{config} for the next admission, or use `hive receipt abandon-batch` for stranded maintenance"
    end
  end
end
