#!/usr/bin/env ruby

require "digest"
require "json"
require "optparse"
require "pathname"
require_relative "proof"

module HiveLiveAgentProof
  module OpenClawCreatorProof
    class Failure < StandardError
      attr_reader :phase, :reason

      def initialize(phase:, reason:, detail:)
        @phase = phase
        @reason = reason
        super(detail)
      end
    end unless const_defined?(:Failure)
  end
end

require_relative "openclaw_creator_proof/installation_receipt"

options = {}
OptionParser.new do |parser|
  parser.on("--output PATH") { |value| options[:path] = value }
  parser.on("--kind KIND") { |value| options[:kind] = value }
  parser.on("--artifact PATH") { |value| options[:artifact_path] = value }
  parser.on("--install-root PATH") { |value| options[:install_root] = value }
  parser.on("--executable PATH") { |value| options[:executable_path] = value }
  parser.on("--interpreter PATH") { |value| options[:interpreter_path] = value }
  parser.on("--package-name NAME") { |value| options[:package_name] = value }
  parser.on("--package-version VERSION") { |value| options[:package_version] = value }
  parser.on("--package-integrity SRI") { |value| options[:package_integrity] = value }
  parser.on("--lock PATH") { |value| options[:lock_path] = value }
  parser.on("--package-count COUNT", Integer) { |value| options[:package_count] = value }
end.parse!

required = %i[
  path kind artifact_path install_root executable_path package_name package_version
]
missing = required.reject { |key| !options[key].to_s.empty? }
abort "missing receipt options: #{missing.join(', ')}" unless missing.empty?

HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(**options)
