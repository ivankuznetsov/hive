#!/usr/bin/env ruby
# frozen_string_literal: true

# render.rb — the single template-rendering path for hive's packaging
# metadata. Both the AUR publish job (.github/workflows/release.yml) and
# the Homebrew tap's update-formula workflow call this so a release's
# version/sha is substituted identically everywhere. This is the
# structural fix for the PKGBUILD/.SRCINFO drift that the hand-maintained
# .SRCINFO.template caused: there is now one renderer, not several.
#
# Usage:
#   ruby packaging/render.rb <template-path> key=value [key=value...]
#
# Example:
#   ruby packaging/render.rb packaging/homebrew/hive.rb.erb \
#     version=0.1.1 sha256_gem=abc123...
#
# The rendered document is written to stdout. A template that references
# a variable not supplied on the command line fails loudly with a
# non-zero exit and writes NOTHING to stdout — a partially-rendered
# formula or PKGBUILD must never reach a published channel.

require "erb"

module Hive
  module PackagingRender
    module_function

    def run(argv)
      template_path, vars = parse_args(argv)
      template = File.read(template_path)
      output = render(template, vars, template_path)
      $stdout.write(output)
      0
    rescue Error => e
      warn "render.rb: #{e.message}"
      2
    end

    def parse_args(argv)
      if argv.empty?
        raise Error, "usage: render.rb <template-path> key=value [key=value...]"
      end

      template_path = argv.first
      unless File.file?(template_path)
        raise Error, "template not found: #{template_path}"
      end

      vars = {}
      argv.drop(1).each do |arg|
        key, value = arg.split("=", 2)
        if value.nil? || key.empty?
          raise Error, "malformed key=value argument: #{arg.inspect}"
        end

        vars[key] = value
      end

      [ template_path, vars ]
    end

    # Render the ERB template against a binding whose only callable
    # identifiers are the supplied keys. A reference to any other bare
    # identifier (e.g. `<%= version %>` when no `version=` was passed)
    # raises NameError/NoMethodError, which we convert into a clear,
    # fail-closed error rather than emitting a half-rendered document.
    def render(template, vars, template_path)
      scope = Object.new
      vars.each { |key, value| scope.define_singleton_method(key) { value } }
      ERB.new(template, trim_mode: "-").result(scope.instance_eval { binding })
    rescue NameError => e
      missing = e.respond_to?(:name) && e.name ? e.name : "(unknown)"
      raise Error,
            "#{template_path}: template references undefined variable `#{missing}` " \
            "(supplied: #{vars.keys.sort.join(', ')}); pass it as #{missing}=<value>"
    end

    class Error < StandardError; end
  end
end

exit(Hive::PackagingRender.run(ARGV)) if $PROGRAM_NAME == __FILE__
