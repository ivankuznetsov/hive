class Hive::AgentSupport::StreamMeter
  TERMINAL_TYPES = %w[result turn.completed response.completed run.completed task.completed].freeze

  attr_reader :total

  def initialize(*)
    @total = 0
    @usage = { input: 0, output: 0, cached: 0, model: nil }
  end

  def observe(event, usage)
    return @total unless usage.is_a?(Hash)

    @usage[:model] = usage[:model] unless usage[:model].to_s.empty?
    terminal?(event) ? replace_with_run_total(usage) : observe_increment(event, usage)
    @total
  end

  def terminal?(event) = event.is_a?(Hash) && TERMINAL_TYPES.include?(event["type"].to_s)
  def usage = @usage.dup

  protected

  def observe_increment(_event, usage) = add_usage(usage)

  def add_usage(usage)
    counts = usage_counts(usage)
    %i[input output cached].each { |key| @usage[key] += counts[key] }
    @total = @usage.values_at(:input, :output).sum
  end

  def replace_with_run_total(usage)
    counts = usage_counts(usage)
    total = counts.values_at(:input, :output).sum
    return if total < @total

    @usage.merge!(counts)
    @total = total
  end

  def usage_counts(usage)
    %i[input output cached].to_h { |key| [ key, [ usage[key].to_i, 0 ].max ] }
  end
end
