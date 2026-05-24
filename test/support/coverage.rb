require "coverage"
require "fileutils"
require "json"
require "time"

module HiveTestCoverage
  LINE_REQUIRED_PERCENT = 100.0

  module_function

  def start!(root:)
    configure!(root: root)
    return if @started

    Coverage.start(lines: true, branches: true)
    @started = true
  end

  def configure!(root:)
    @root = File.expand_path(root)
    @lib_dir = File.join(@root, "lib")
    @coverage_dir = File.join(@root, "coverage")
    run_id = ENV.fetch("HIVE_COVERAGE_RUN_ID", "default")
    @resultset_dir = File.join(@coverage_dir, ".resultset", run_id)
  end

  def install_reporter!
    return unless @started
    return if @reporter_installed

    Minitest.after_run do
      dump_process_result!
      report!
    end
    @reporter_installed = true
  end

  def load_all_sources!
    reload_preloaded_entrypoint!
    source_files.each do |path|
      feature = path.delete_prefix("#{@lib_dir}/").delete_suffix(".rb")
      require feature
    end
  end

  def reload_preloaded_entrypoint!
    old_verbose = $VERBOSE
    path = File.join(@root, "lib", "hive.rb")
    return unless $LOADED_FEATURES.include?(path)

    # Bundler evaluates the gemspec before RUBYOPT coverage boots, and the
    # gemspec requires lib/hive.rb for Hive::VERSION. Reload only the entrypoint
    # under coverage so the unloaded-file gate can stay strict.
    $VERBOSE = nil
    load path
  ensure
    $VERBOSE = old_verbose
  end

  def dump_process_result!
    return unless @started
    return if @dumped

    FileUtils.mkdir_p(@resultset_dir)
    path = File.join(@resultset_dir, "#{Process.pid}-#{object_id}.marshal")
    tmp_path = "#{path}.tmp"
    File.binwrite(tmp_path, Marshal.dump(Coverage.result))
    File.rename(tmp_path, path)
    @dumped = true
  rescue RuntimeError
    # Coverage.result raises if another at_exit hook already stopped it.
    @dumped = true
  end

  def report!
    result = merged_results
    report = build_report(result, result_errors: @result_errors || [])
    write_report(report)
    print_report(report)
  end

  def merged_results
    @result_errors = []
    merged = {}
    Dir.glob(File.join(@resultset_dir, "*.marshal")).sort.each do |path|
      merge_result!(merged, Marshal.load(File.binread(path)))
    rescue StandardError => e
      @result_errors << {
        file: path.delete_prefix("#{@root}/"),
        error_class: e.class.name,
        message: e.message
      }
      warn "hive coverage: unreadable result #{path}: #{e.class}: #{e.message}"
    end
    merged
  end

  def merge_result!(merged, result)
    result.each do |path, entry|
      expanded = File.expand_path(path)
      next unless expanded.start_with?("#{@lib_dir}/") || expanded == File.join(@root, "lib", "hive.rb")

      merged[expanded] = merge_entry(merged[expanded], entry)
    end
  end

  def merge_entry(existing, incoming)
    return incoming unless existing

    {
      lines: merge_lines(existing[:lines], incoming[:lines]),
      branches: merge_branches(existing[:branches], incoming[:branches])
    }
  end

  def merge_lines(left, right)
    max = [ left&.length || 0, right&.length || 0 ].max
    Array.new(max) do |index|
      counts = [ left&.[](index), right&.[](index) ].compact
      counts.empty? ? nil : counts.sum
    end
  end

  def merge_branches(left, right)
    merged = deep_dup_branches(left || {})
    (right || {}).each do |decision, outcomes|
      merged[decision] ||= {}
      outcomes.each do |outcome, count|
        merged[decision][outcome] = merged[decision].fetch(outcome, 0) + count
      end
    end
    merged
  end

  def deep_dup_branches(branches)
    branches.each_with_object({}) do |(decision, outcomes), copy|
      copy[decision] = outcomes.dup
    end
  end

  def build_report(result, result_errors: @result_errors || [])
    coverage_by_path = result.transform_keys { |path| File.expand_path(path) }
    files = source_files.map do |path|
      file_report(path, coverage_by_path[File.expand_path(path)])
    end

    line_total = files.sum { |file| file.fetch(:line_total) }
    line_covered = files.sum { |file| file.fetch(:line_covered) }
    branch_total = files.sum { |file| file.fetch(:branch_total) }
    branch_covered = files.sum { |file| file.fetch(:branch_covered) }
    unloaded_files = files.select { |file| !file.fetch(:loaded) && file.fetch(:line_total).positive? }
      .map { |file| file.fetch(:file) }

    report = {
      generated_at: Time.now.utc.iso8601,
      process_results: Dir.glob(File.join(@resultset_dir, "*.marshal")).size,
      line_required_percent: LINE_REQUIRED_PERCENT,
      line_total: line_total,
      line_covered: line_covered,
      line_percent: percent(line_covered, line_total),
      branch_total: branch_total,
      branch_covered: branch_covered,
      branch_percent: percent(branch_covered, branch_total),
      unloaded_files: unloaded_files,
      result_errors: result_errors,
      files: files
    }
    report[:ok] = coverage_ok?(report)
    report
  end

  def file_report(path, entry)
    relative = path.delete_prefix("#{@root}/")
    lines = entry ? entry.fetch(:lines, nil) || [] : unloaded_line_stub(path)
    branches = entry&.fetch(:branches, {})
    uncovered_lines = []
    line_total = 0
    line_covered = 0

    lines.each_with_index do |count, index|
      next if count.nil?

      line_total += 1
      if count.positive?
        line_covered += 1
      else
        uncovered_lines << index + 1
      end
    end

    branch_total = 0
    branch_covered = 0
    uncovered_branches = []
    branches&.each do |decision, outcomes|
      outcomes.each do |outcome, count|
        branch_total += 1
        if count.positive?
          branch_covered += 1
        else
          uncovered_branches << branch_description(decision, outcome)
        end
      end
    end

    {
      file: relative,
      loaded: !entry.nil?,
      line_total: line_total,
      line_covered: line_covered,
      line_percent: percent(line_covered, line_total),
      uncovered_lines: uncovered_lines,
      branch_total: branch_total,
      branch_covered: branch_covered,
      branch_percent: percent(branch_covered, branch_total),
      uncovered_branches: uncovered_branches
    }
  end

  def unloaded_line_stub(path)
    if Coverage.respond_to?(:line_stub)
      stub = Coverage.line_stub(path)
      return stub if stub
    end

    File.readlines(path).map do |line|
      stripped = line.strip
      stripped.empty? || stripped.start_with?("#") ? nil : 0
    end
  rescue StandardError
    []
  end

  def branch_description(decision, outcome)
    {
      decision: branch_id(decision),
      outcome: branch_id(outcome),
      line: branch_line(outcome) || branch_line(decision)
    }
  end

  def branch_id(value)
    parts = value.to_a
    parts.first.to_s
  end

  def branch_line(value)
    parts = value.to_a
    parts[2] if parts[2].is_a?(Integer)
  end

  def source_files
    Dir.glob(File.join(@lib_dir, "**/*.rb")).sort
  end

  def write_report(report)
    FileUtils.mkdir_p(@coverage_dir)
    File.write(File.join(@coverage_dir, "coverage.json"), JSON.pretty_generate(report))
  end

  def read_report(path)
    JSON.parse(File.read(path))
  end

  def coverage_ok?(report)
    numeric_value(report, :line_covered) == numeric_value(report, :line_total) &&
      Array(value(report, :unloaded_files)).empty? &&
      Array(value(report, :result_errors)).empty?
  end

  def failure_lines(report)
    lines = []
    line_covered = numeric_value(report, :line_covered)
    line_total = numeric_value(report, :line_total)
    if line_covered != line_total
      lines << format(
        "line coverage %.2f%% (%d/%d), required %.2f%%",
        numeric_value(report, :line_percent),
        line_covered,
        line_total,
        numeric_value(report, :line_required_percent)
      )
    end

    unloaded_files = Array(value(report, :unloaded_files))
    lines << "unloaded executable source files: #{unloaded_files.join(', ')}" unless unloaded_files.empty?

    result_errors = Array(value(report, :result_errors))
    unless result_errors.empty?
      lines << "unreadable subprocess coverage results: #{result_errors.map { |error| value(error, :file) }.join(', ')}"
    end

    lines
  end

  def failure_message(report)
    lines = failure_lines(report)
    return "Coverage gate failed" if lines.empty?

    ([ "Coverage gate failed:" ] + lines.map { |line| "  - #{line}" }).join("\n")
  end

  def print_report(report)
    warn ""
    warn "Coverage summary"
    warn "  Process results: #{report.fetch(:process_results)}"
    warn "  Gate:           #{report.fetch(:ok) ? 'passed' : 'failed'}"
    warn format(
      "  Lines:          %.2f%% (%d/%d)",
      report.fetch(:line_percent),
      report.fetch(:line_covered),
      report.fetch(:line_total)
    )
    warn format(
      "  Branches:       %.2f%% (%d/%d)",
      report.fetch(:branch_percent),
      report.fetch(:branch_covered),
      report.fetch(:branch_total)
    )
    warn "  Details:        coverage/coverage.json"

    lowest = report.fetch(:files)
      .reject { |file| file.fetch(:line_total).zero? }
      .sort_by { |file| [ file.fetch(:line_percent), -file.fetch(:uncovered_lines).length, file.fetch(:file) ] }
      .first(15)

    warn ""
    warn "Lowest line coverage"
    lowest.each do |file|
      warn format(
        "  %6.2f%%  %4d/%-4d  %s",
        file.fetch(:line_percent),
        file.fetch(:line_covered),
        file.fetch(:line_total),
        file.fetch(:file)
      )
    end

    warn ""
    warn failure_message(report) unless report.fetch(:ok)

    uncovered = report.fetch(:files).select { |file| file.fetch(:uncovered_lines).any? }
    return if uncovered.empty?

    warn ""
    warn "Uncovered lines"
    uncovered.first(30).each do |file|
      warn "  #{file.fetch(:file)}: #{compact_lines(file.fetch(:uncovered_lines))}"
    end
  end

  def compact_lines(lines)
    text = lines.first(80).join(", ")
    lines.length > 80 ? "#{text}, ..." : text
  end

  def value(hash, key)
    hash[key] || hash[key.to_s]
  end

  def numeric_value(hash, key)
    value(hash, key).to_f
  end

  def percent(covered, total)
    return 100.0 if total.zero?

    (covered.to_f / total * 100).round(2)
  end
end
