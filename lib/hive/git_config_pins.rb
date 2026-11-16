# frozen_string_literal: true

module Hive
  # Git config Hive pins for unattended git that still inherits the operator's
  # config: git that agents run themselves, and Hive's own conflict-producing
  # rebase. Hive's managed git (behind Hive::AgentGitGate) does not need it;
  # it already ignores global config.
  #
  # Inheriting the operator's config keeps identity, signing, and credential
  # helpers working, but some of it is unsafe without a human watching.
  # `rerere.enabled` + `rerere.autoupdate` make `git merge` and `git rebase`
  # silently stage a resolution recorded for an older conflict. On todero
  # PR #57 that downgraded brakeman in Gemfile.lock.
  #
  # The pins are GIT_CONFIG_COUNT/KEY_n/VALUE_n entries. These override every
  # config file but not an explicit `git -c`. They go after any entries the
  # child would already see, so earlier entries keep their indices.
  module GitConfigPins
    PINS = [
      %w[rerere.enabled false],
      %w[rerere.autoupdate false]
    ].freeze
    COUNT_KEY = "GIT_CONFIG_COUNT"
    # Git reads the count with strtoul and rejects trailing bytes, so leading
    # whitespace and a plus sign are accepted. Anything else is a "bogus count".
    GIT_COUNT = /\A\s*\+?([0-9]+)\z/

    module_function

    # `environment` is the override hash a child is spawned with. `inherited`
    # supplies any key the overrides leave out: ENV for a normal spawn, {}
    # under `unsetenv_others`. A nil override unsets the key.
    #
    # If git would reject the existing count, the environment is returned
    # unchanged. Git then refuses every command ("unable to parse
    # command-line config"), so no merge can run. Hive does not guess which
    # entries the operator meant.
    def apply(environment, inherited: {})
      raw = environment.key?(COUNT_KEY) ? environment[COUNT_KEY] : inherited[COUNT_KEY]
      count = existing_count(raw)
      return environment if count.nil?

      environment.merge(entries(count))
    end

    def existing_count(raw)
      return 0 if raw.nil? || raw.empty?

      match = GIT_COUNT.match(raw)
      match && Integer(match[1], 10)
    end

    def entries(offset)
      pinned = { COUNT_KEY => (offset + PINS.length).to_s }
      PINS.each_with_index do |(key, value), index|
        pinned["GIT_CONFIG_KEY_#{offset + index}"] = key
        pinned["GIT_CONFIG_VALUE_#{offset + index}"] = value
      end
      pinned
    end
  end
end
