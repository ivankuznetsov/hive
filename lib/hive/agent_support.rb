module Hive::AgentSupport
  BUILTINS = { pi: "Pi", opencode: "OpenCode", codex: "Codex", grok: "Grok" }.freeze
  DEFAULT_PROMPT_STYLES = { codex: :stdin }.freeze
  PROTOCOLS = { grok_end: :grok }.freeze

  module SkillPolicy
    def verify(invocation, **options)
      resolve(invocation, **options).then { |result| [ result.status, result.message ] }
    end

    private

    def resolution(status, candidates, parse_errors = [], path: nil, message:)
      Hive::SkillCheck::Resolution.new(
        status:, path:, message:, candidates: candidates.freeze,
        parse_errors: parse_errors.freeze
      )
    end
  end

  def self.skill_verifier(profile) = ->(*args, **options) { self.for(profile)::Skills.verify(*args, **options) }
  def self.model_resolver(profile) = ->(**options) { self.for(profile).default_model(**options) }

  def self.for(profile)
    name = profile.respond_to?(:name) ? profile.name : profile
    return if name.nil?

    constant = BUILTINS[name.to_sym] or return

    require "hive/agent_support/#{name}"
    const_get(constant, false)
  end

  def self.for_protocol(protocol) = self.for(PROTOCOLS[protocol&.to_sym])
end
