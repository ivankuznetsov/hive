module Hive::AgentSupport
  BUILTINS = { pi: "Pi" }.freeze

  def self.for(profile)
    name = profile.respond_to?(:name) ? profile.name : profile
    constant = BUILTINS[name.to_sym] or return

    require "hive/agent_support/#{name}"
    const_get(constant, false)
  end
end
