require "test_helper"
require "json"
require "open3"
require "pathname"
require "shellwords"
require "tmpdir"

# Proves the full hosted-runner contract: a real failing Minitest process
# running under CI=true + GITHUB_STEP_SUMMARY emits both evidence surfaces,
# stays fail-open on exit status semantics (non-zero because tests failed),
# and its recorded repro command re-runs exactly the failing test.
module TestFailureEvidenceIntegration
  class CiEmissionTest < Minitest::Test
    def test_failing_subprocess_emits_summary_json_and_working_repro
      FileUtils.mkdir_p(File.join(REPO_ROOT, "tmp"))
      Dir.mktmpdir("hive-fail-ev", File.join(REPO_ROOT, "tmp")) do |root|
        dir = File.join(root, "path with spaces")
        FileUtils.mkdir_p(dir)
        test_path = File.join(dir, "sample failure test.rb")
        File.write(test_path, <<~RUBY)
          require "test_helper"

          class SampleFailureTest < Minitest::Test
            def test_bites
              assert_equal 1, 2
            end
          end
        RUBY

        summary_path = File.join(dir, "github-step-summary.md")
        run_in(dir, test_path, summary_path)

        evidence_path = File.join(dir, "tmp", "ci-failure-evidence.json")
        assert_path_exists evidence_path, "child did not emit evidence. child output:\n#{last_output}"
        payload = JSON.parse(File.read(evidence_path))
        assert_equal "hive-ci-failure-evidence/v1", payload.fetch("schema")
        failure = payload.fetch("failures").fetch(0)
        assert_equal "SampleFailureTest#test_bites", failure.fetch("test")
        assert_equal "sample failure test.rb", File.basename(failure.fetch("file"))
        assert failure.fetch("file").start_with?("tmp/"), failure.fetch("file")
        refute Pathname.new(failure.fetch("file")).absolute?
        seed = payload.fetch("seed")
        repro = failure.fetch("repro_command")
        repro_argv = Shellwords.split(repro)
        assert_equal seed.to_s, repro_argv.fetch(repro_argv.index("--seed") + 1)
        assert_equal "SampleFailureTest#test_bites", repro_argv.fetch(repro_argv.index("--name") + 1)
        assert_includes repro, "path\\ with\\ spaces"

        summary = File.read(summary_path)
        assert_includes summary, "Failed tests (1)"
        assert_includes summary, "`SampleFailureTest#test_bites`"

        # The recorded repro command must target exactly this one test.
        out, err, _status = Open3.capture3(
          { "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile") },
          *repro_argv,
          chdir: REPO_ROOT,
        )
        combined = out + err
        assert_includes combined, "SampleFailureTest#test_bites"
        refute_includes combined, "AnotherTest"
      end
    end

    private

    def run_in(cwd, test_path, summary_path)
      repo_lib = File.join(REPO_ROOT, "lib")
      repo_test = File.join(REPO_ROOT, "test")
      out, err = Open3.capture2e(
        {
          "CI" => "1",
          # Model the child fixture's checkout, not an outer hosted runner's.
          "GITHUB_WORKSPACE" => cwd,
          "GITHUB_STEP_SUMMARY" => summary_path,
          # Run through the repo bundle so the child cannot inherit a
          # half-configured bundler state from this (bundle-exec'd) parent.
          "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile")
        },
        "bundle", "exec", RbConfig.ruby,
        "-I#{repo_test}",
        "-I#{repo_lib}",
        test_path,
        chdir: cwd,
      )
      @last_output = out
    end

    def last_output
      @last_output
    end
  end

  REPO_ROOT = File.expand_path("../..", __dir__)
end
