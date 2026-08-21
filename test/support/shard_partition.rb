# Frozen_string_literal: true

# CI coverage-shard partitioning. Prefers measured per-file runtimes from the
# checked-in sweep timings file (greedy longest-processing-time, which
# balances wall-clock rather than byte size); falls back to the historical
# byte-size heuristic with its hand-tuned hot/tail split when timings are
# absent or unusable. Partitioning only decides which files run where — it
# never changes what is proven.
module HiveShardPartition
  STALENESS_SECONDS = 14 * 24 * 60 * 60

  module_function

  def partition(files:, count:, timings: nil, now: Time.now)
    if usable_timings?(timings)
      by_runtime(files, count, timings)
    else
      by_bytes_hot_tail(files, count)
    end
  end

  def usable_timings?(timings)
    timings.is_a?(Hash) && timings.any?
  end

  def stale?(path, now: Time.now)
    return false unless path && File.exist?(path)

    (now - File.mtime(path)) > STALENESS_SECONDS
  end

  # Greedy longest-processing-time: each file lands on the currently
  # lightest shard. Deterministic for identical inputs.
  def by_runtime(files, count, timings)
    shards = Array.new(count) { [] }
    loads = Array.new(count, 0.0)

    files.sort_by { |path| [ -(Float(timings[path] || 0)), path ] }.each do |path|
      target = loads.each_index.min_by { |index| [ loads[index], index ] }
      shards.fetch(target) << path
      loads[target] += Float(timings.fetch(path, 0))
    end

    finish(shards)
  end

  def by_bytes_hot_tail(files, count)
    # Historical hosted-run tuning: split the two measured hot partitions of
    # the four-way byte partition. Exact for the production shard count of 6;
    # other counts fall back to a plain byte partition.
    return by_bytes(files, count) unless count == 6

    base = by_bytes(files, 4)
    hot_shards = by_bytes(base.fetch(2), 2)
    tail_shards = by_bytes(base.fetch(3), 2)
    finish([ base[0], base[1], *hot_shards, *tail_shards ])
  end

  def by_bytes(files, count)
    shards = Array.new(count) { [] }
    shard_bytes = Array.new(count, 0)

    files.sort_by { |path| [ -File.size(path), path ] }.each do |path|
      shard = shard_bytes.each_index.min_by { |index| [ shard_bytes[index], index ] }
      shards.fetch(shard) << path
      shard_bytes[shard] += File.size(path)
    end

    shards
  end

  def finish(shards)
    shards.each(&:freeze)
    shards.freeze
  end
end
