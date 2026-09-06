require "json"

# Longest-processing-time partitioning. Unknown files use a median measured
# runtime, so new files do not all accumulate in an apparently empty shard.
module HiveTestPartition
  DEFAULT_TIMINGS = File.expand_path("shard_timings.json", __dir__)

  def self.partition(files, count:, root: Dir.pwd, timings_path: DEFAULT_TIMINGS)
    raise ArgumentError, "partition count must be a positive integer" unless count.is_a?(Integer) && count.positive?
    raise ArgumentError, "duplicate test files" unless files.uniq == files

    timings = read_timings(timings_path)
    known = files.filter_map { |file| timings[file] }.sort
    fallback = known.empty? ? 1.0 : [ known[known.length / 2], 0.01 ].max
    costs = files.to_h do |file|
      cost = if known.empty?
        begin
          stat = File.stat(File.join(root, file))
          stat.file? ? [ stat.size, 1 ].max : 1
        rescue Errno::ENOENT, Errno::ENOTDIR
          1
        end
      else
        timings.fetch(file, fallback)
      end
      [ file, cost ]
    end
    shards = Array.new(count) { [] }
    totals = Array.new(count, 0.0)
    files.sort_by { |file| [ -costs.fetch(file), file ] }.each do |file|
      index = totals.each_index.min_by { |i| [ totals[i], shards[i].length, i ] }
      shards[index] << file
      totals[index] += costs.fetch(file)
    end
    shards
  end

  def self.read_timings(path)
    data = JSON.parse(File.read(path))
    return {} unless data.is_a?(Hash) && data["schema"] == "hive-shard-timings.v1"
    values = data["seconds_per_run"]
    return {} unless values.is_a?(Hash)

    values.select do |file, seconds|
      file.is_a?(String) && seconds.is_a?(Numeric) && seconds.finite? && seconds.positive? && seconds <= 86_400
    end
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end
end
