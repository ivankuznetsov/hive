# frozen_string_literal: true

require "optparse"
require "shellwords"
require "bundler"
require_relative "../test/support/changed_coverage"

module HiveChangedTestRunner
  module_function

  def commands(selection, options: [])
    commands = []
    unless selection[:root].empty?
      runner = selection[:root].length > 1 ? [ "bundle", "exec", "ruby", "script/test_parallel.rb" ] : [ "bin/test" ]
      commands << [ ".", [ *runner, *selection[:root], *options ] ]
    end
    selection[:components].each do |component, files|
      next if files.empty?

      loader = "ARGV.shift(Integer(ARGV.shift)).each { |file| require File.expand_path(file) }"
      commands << [ ".", [ "bundle", "exec", "ruby", "-I#{component}/test", "-I#{component}/lib",
                           "-e", loader, files.length.to_s, *files, *options ] ]
    end
    # Rails has its own Gemfile and test loader. Keep browser tests in their own process.
    selection[:web].partition { |file| file.start_with?("web/test/system/") }.each do |files|
      next if files.empty?

      commands << [ "web", [ "bundle", "exec", "ruby", "bin/rails", "test",
                             *files.map { |file| file.delete_prefix("web/") }, *options ] ]
    end
    commands
  end

  def run(arguments, output: $stdout, error: $stderr, executor: nil)
    base = ENV.fetch("HIVE_COVERAGE_BASE", "origin/main")
    list = false
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: bin/test --changed [--base REF] [--list] [-- MINITEST_OPTIONS]"
      opts.on("--base REF") { |value| base = value }
      opts.on("--list") { list = true }
    end
    options = arguments.dup
    parser.parse!(options)
    paths = HiveChangedCoverage.changed_paths(base: base)
    selection = HiveChangedCoverage.selection(paths: paths)
    output.puts "Changed test selection versus merge-base with #{base}: #{paths.length} changed paths"
    selection[:reasons].each { |reason| output.puts "  #{reason}" }
    commands = commands(selection, options: options)
    commands.each { |directory, command| output.puts "  (#{directory}) #{Shellwords.join(command)}" }
    if commands.empty?
      output.puts "No runnable tests selected (#{selection[:ignored].length} documentation paths)."
      return 0
    end
    return 0 if list

    executor ||= lambda do |directory, command|
      Bundler.with_unbundled_env do
        system({ "BUNDLE_GEMFILE" => File.expand_path("Gemfile", directory) }, *command, chdir: directory)
        $?.exitstatus || 1
      end
    end
    commands.each do |directory, command|
      status = executor.call(directory, command)
      return status unless status == 0
    end
    0
  rescue OptionParser::ParseError, RuntimeError, SystemCallError => exception
    error.puts "bin/test --changed: #{exception.message}"
    1
  end
end

exit HiveChangedTestRunner.run(ARGV) if $PROGRAM_NAME == __FILE__
