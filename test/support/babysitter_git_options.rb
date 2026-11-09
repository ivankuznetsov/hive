require "json"

module BabysitterGitOptions
  SPELLINGS = JSON.parse(File.read(
    File.expand_path("../fixtures/babysitter/git_option_spellings.v1.json", __dir__)
  )).freeze

  CAPABILITY_PROBE_ARGV = %w[--no-lazy-fetch --version].freeze
end
