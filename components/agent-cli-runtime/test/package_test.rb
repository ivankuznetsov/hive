require_relative "test_helper"

class AgentCliRuntimePackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_build_candidate_records_one_exact_gem
    Dir.mktmpdir do |dir|
      dirty, git_error, git_status = Open3.capture3(
        "git", "-C", File.expand_path("../..", ROOT), "status", "--porcelain"
      )
      assert git_status.success?, git_error

      out, err, status = Open3.capture3(
        File.join(ROOT, "bin", "build-candidate"),
        dir
      )

      assert status.success?, err
      manifest = JSON.parse(out.lines.last)
      gem_path = manifest.fetch("gem_path")
      assert File.file?(gem_path)
      assert_equal "agent-cli-runtime-0.1.0.gem", File.basename(gem_path)
      assert_equal Digest::SHA256.file(gem_path).hexdigest,
                   manifest.fetch("sha256")
      assert_equal !dirty.empty?, manifest.fetch("source_dirty")
      assert_equal "#{manifest.fetch('sha256')}  #{File.basename(gem_path)}\n",
                   File.read(File.join(dir, "SHA256SUMS"))
    end
  end

  def test_release_preflight_accepts_only_the_clean_tagged_main_commit
    with_release_repository do |repository, component, commit, tag|
      out, err, status = run_preflight(component, tag, commit, "main")
      assert status.success?, err
      assert_equal commit, JSON.parse(out).fetch("commit")

      File.write(File.join(component, "README.md"), "\ndirty\n", mode: "a")
      _out, err, status = run_preflight(component, tag, commit, "main")
      refute status.success?
      assert_match(/release checkout is dirty/, err)
    end
  end

  def test_release_preflight_rejects_malformed_identity_inputs
    with_release_repository do |_repository, component, commit, _tag|
      {
        "v0.1.0" => /invalid component tag/,
        "components/agent-cli-runtime/v0.1.1" => /tag\/source version mismatch/
      }.each do |tag, message|
        _out, err, status = run_preflight(component, tag, commit, "main")
        refute status.success?, tag
        assert_match message, err
      end

      _out, err, status = run_preflight(
        component, "components/agent-cli-runtime/v0.1.0",
        commit[0, 12], "main"
      )
      refute status.success?
      assert_match(/expected commit must be a full SHA/, err)
    end
  end

  def test_release_preflight_rejects_checkout_and_tag_commit_mismatches
    with_release_repository do |repository, component, commit, tag|
      File.write(File.join(repository, "second"), "second\n")
      git!(repository, "add", "second")
      commit_fixture!(repository, "second")
      second_commit = git!(repository, "rev-parse", "HEAD").strip

      _out, err, status = run_preflight(component, tag, commit, "main")
      refute status.success?
      assert_match(/does not match expected commit/, err)

      _out, err, status = run_preflight(
        component, tag, second_commit, "main"
      )
      refute status.success?
      assert_match(/does not resolve to expected commit/, err)
    end
  end

  def test_release_preflight_rejects_commit_not_reachable_from_main
    with_release_repository do |repository, component, _commit, tag|
      git!(repository, "checkout", "--quiet", "-b", "candidate")
      File.write(File.join(repository, "candidate"), "candidate\n")
      git!(repository, "add", "candidate")
      commit_fixture!(repository, "candidate")
      candidate_commit = git!(repository, "rev-parse", "HEAD").strip
      git!(repository, "tag", "--force", tag, candidate_commit)

      _out, err, status = run_preflight(
        component, tag, candidate_commit, "main"
      )
      refute status.success?
      assert_match(/candidate is not reachable from main/, err)
    end
  end

  private

  def with_release_repository
    Dir.mktmpdir do |repository|
      component = File.join(repository, "components", "agent-cli-runtime")
      FileUtils.mkdir_p(File.dirname(component))
      FileUtils.cp_r(ROOT, component)

      git!(repository, "init", "--quiet")
      git!(repository, "checkout", "--quiet", "-b", "main")
      git!(repository, "add", ".")
      commit_fixture!(repository, "fixture")
      commit = git!(repository, "rev-parse", "HEAD").strip
      tag = "components/agent-cli-runtime/v0.1.0"
      git!(repository, "tag", tag)

      yield repository, component, commit, tag
    end
  end

  def commit_fixture!(repository, message)
    git!(
      repository,
      "-c", "user.name=Agent CLI Runtime Test",
      "-c", "user.email=agent-cli-runtime@example.invalid",
      "commit", "--quiet", "-m", message
    )
  end

  def run_preflight(component, *arguments)
    Open3.capture3(
      File.join(component, "bin", "release-preflight"),
      *arguments
    )
  end

  def git!(repository, *arguments)
    out, err, status = Open3.capture3("git", "-C", repository, *arguments)
    assert status.success?, err
    out
  end
end
