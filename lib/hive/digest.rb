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
    Result = Data.define(:status, :date, :message, :delivery)

    module_function

    def run(date: nil, dry_run: false, cfg: {}, clock: -> { Time.now },
            collector: nil, categorizer: nil, sender: nil)
      local_date = date ? Window.parse_date(date) : Window.local_today(now: clock.call) - 1
      collector ||= Collector.new
      sender ||= Sender.new(cfg: cfg)

      grouped = collector.for_date(local_date)
      message, status =
        if empty_grouped?(grouped)
          [ Renderer.empty, :empty ]
        else
          render_digest(grouped, local_date, cfg, categorizer)
        end

      delivery = sender.deliver(message, dry_run: dry_run)
      Result.new(status: status, date: local_date, message: message, delivery: delivery)
    rescue ModelError
      message = Renderer.failed(local_date || date)
      delivery = (sender || Sender.new(cfg: cfg)).deliver(message, dry_run: dry_run)
      Result.new(status: :failed_notice, date: local_date || Window.parse_date(date), message: message, delivery: delivery)
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
