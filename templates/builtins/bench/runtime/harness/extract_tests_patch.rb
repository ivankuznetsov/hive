# frozen_string_literal: true

# Extracts the TEST-ONLY portion of a corpus entry's reference.patch into
# gate/tests.patch — the held-out test overlay the gate applies over candidate
# diffs (SWE-bench style). Test-only = hunks for files under test/.
#
#   ruby harness/extract_tests_patch.rb corpus/<task-id>
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

module HiveBench
  module ExtractTestsPatch
    module_function

    # Splits a unified diff into per-file chunks, keeps NEW files under test/.
    # Modified existing test files are excluded on purpose: candidates edit
    # test files too, and overlay conflicts there would gate-error working
    # solutions. New reference test files only collide if the candidate created
    # the identical path — rare, and an honest error when it happens.
    def test_only(patch)
      chunks = patch.split(/^(?=diff --git )/)
      chunks.select do |c|
        c[%r{\Adiff --git a/(\S+)}, 1]&.start_with?("test/") && c.match?(/^new file mode/)
      end.join
    end
  end
end

if $PROGRAM_NAME == __FILE__
  entry_dir = ARGV[0] or abort("usage: ruby harness/extract_tests_patch.rb corpus/<task-id>")
  patch = File.read(File.join(entry_dir, "reference.patch"))
  tests = HiveBench::ExtractTestsPatch.test_only(patch)
  abort("no test/ hunks in reference.patch") if tests.empty?
  out = File.join(entry_dir, "gate", "tests.patch")
  File.write(out, tests)
  files = tests.scan(%r{^diff --git a/(\S+)}).flatten
  warn "wrote #{out}: #{files.size} test file(s)\n#{files.map { |f| "  #{f}" }.join("\n")}"
end
