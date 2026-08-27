# Repository-internal conformance suite for agent-cli-runtime.
#
# This file is the single owner of the candidate conformance decisions that
# both the source test suite and bin/verify-candidate must agree on:
#
#   * the complete ordered provider inventory of the package, and
#   * the OpenCode non-interactive capability inventory that the pinned CLI
#     surface, fixture corpus, synthetic probe stub, and installed-candidate
#     probe must all advertise.
#
# It deliberately lives under test/support so the gem never packages it;
# bin/verify-candidate loads it from the repository checkout and the test
# suite loads it through test/test_helper.rb. Shipped library behavior keeps
# its own public definitions; test/conformance_suite_test.rb proves this
# internal declaration and every consumer stay in agreement.

module AgentCliRuntime
  module Conformance
    # Complete ordered built-in provider inventory of the installed candidate
    # and the source CLI contract.
    PROVIDER_NAMES = %i[claude codex pi grok opencode].freeze

    # OpenCode "run --help" capabilities required by the pinned v1.18.16
    # contract. Order matches the fixture corpus rendering.
    OPENCODE_RUN_FLAGS = %w[--pure --model --format --dir --variant --auto].freeze

    # OpenCode "export --help" capabilities required by the same contract.
    OPENCODE_EXPORT_FLAGS = %w[--sanitize].freeze

    module_function

    # Renders the synthetic OpenCode "run --help" payload used by the
    # bin/verify-candidate probe stub. Only advertised flag tokens are
    # contractual; surrounding text is opaque to the probe.
    def opencode_run_help
      OPENCODE_RUN_FLAGS.join(" ")
    end

    # Renders the synthetic OpenCode "export --help" payload.
    def opencode_export_help
      OPENCODE_EXPORT_FLAGS.join(" ")
    end
  end
end
