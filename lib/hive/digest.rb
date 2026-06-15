require "date"
require "hive/config"
require "hive/digest/errors"
require "hive/digest/window"
require "hive/digest/shipped_item"
require "hive/digest/ship_times"
require "hive/digest/collector"
require "hive/digest/categorizer"
require "hive/digest/renderer"
require "hive/digest/sender"

module Hive
  module Digest
    Result = Data.define(:status, :date, :message, :delivery) do
      STATUSES = %i[empty sent failed_notice].freeze

      # Guard the status invariant at the boundary: only the three known
      # outcomes are constructible, so a typo'd symbol can't slip through.
      def initialize(status:, date:, message:, delivery:)
        raise ArgumentError, "digest status must be one of #{STATUSES.inspect}; got #{status.inspect}" \
          unless STATUSES.include?(status)

        super
      end
    end

    module_function

    def run(date: nil, dry_run: false, cfg: nil, clock: -> { Time.now },
            collector: nil, categorizer: nil, sender: nil)
      local_date = date ? Window.parse_date(date) : Window.local_today(now: clock.call) - 1
      cfg ||= Hive::Config.load_global_digest_config
      collector ||= Collector.new
      sender ||= Sender.new(cfg: cfg)

      grouped = collector.for_date(local_date)
      message, status =
        if empty_grouped?(grouped)
          [ Renderer.empty, :empty ]
        else
          # Resolve the recipient + token BEFORE the paid categorizer
          # run so a missing chat_id / unset token fails fast instead of
          # wasting a full LLM run (and, with the scheduler's backoff,
          # hot-looping it). Skipped for dry-run, which never sends.
          sender.preflight! unless dry_run
          render_digest(grouped, local_date, cfg, categorizer)
        end

      delivery = sender.deliver(message, dry_run: dry_run)
      Result.new(status: status, date: local_date, message: message, delivery: delivery)
    rescue ModelError
      # `local_date` and `sender` are always assigned above before any
      # categorization can raise ModelError, so no nil-fallbacks needed.
      message = Renderer.failed(local_date)
      delivery = sender.deliver(message, dry_run: dry_run)
      Result.new(status: :failed_notice, date: local_date, message: message, delivery: delivery)
    end

    def empty_grouped?(grouped)
      grouped.empty? || grouped.values.all? { |items| Array(items).empty? }
    end

    def render_digest(grouped, date, cfg, categorizer)
      categorizer ||= Categorizer.new(cfg: cfg)
      categorized = categorizer.categorize(grouped, date: date)
      [ Renderer.render(categorized), :sent ]
    end
  end
end
