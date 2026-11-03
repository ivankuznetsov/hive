# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

module BenchHarness
  HARNESS_ROOT = File.expand_path("../../templates/builtins/bench/runtime/harness", __dir__)
end
$LOAD_PATH.unshift(BenchHarness::HARNESS_ROOT) unless $LOAD_PATH.include?(BenchHarness::HARNESS_ROOT)
