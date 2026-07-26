require_relative "test_helper"

class AgentCliRuntimePackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_build_candidate_records_one_exact_gem
    Dir.mktmpdir do |dir|
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
      assert_includes [ true, false ], manifest.fetch("source_dirty")
      assert_equal "#{manifest.fetch('sha256')}  #{File.basename(gem_path)}\n",
                   File.read(File.join(dir, "SHA256SUMS"))
    end
  end

  def test_release_preflight_accepts_only_the_clean_tagged_main_commit
    Dir.mktmpdir do |repository|
      component = File.join(repository, "components", "agent-cli-runtime")
      FileUtils.mkdir_p(File.dirname(component))
      FileUtils.cp_r(ROOT, component)

      git!(repository, "init", "--quiet")
      git!(repository, "checkout", "--quiet", "-b", "main")
      git!(repository, "add", ".")
      git!(
        repository,
        "-c", "user.name=Agent CLI Runtime Test",
        "-c", "user.email=agent-cli-runtime@example.invalid",
        "commit", "--quiet", "-m", "fixture"
      )
      commit = git!(repository, "rev-parse", "HEAD").strip
      tag = "components/agent-cli-runtime/v0.1.0"
      git!(repository, "tag", tag)

      out, err, status = Open3.capture3(
        File.join(component, "bin", "release-preflight"),
        tag, commit, "main"
      )
      assert status.success?, err
      assert_equal commit, JSON.parse(out).fetch("commit")

      File.write(File.join(component, "README.md"), "\ndirty\n", mode: "a")
      _out, err, status = Open3.capture3(
        File.join(component, "bin", "release-preflight"),
        tag, commit, "main"
      )
      refute status.success?
      assert_match(/release checkout is dirty/, err)
    end
  end

  private

  def git!(repository, *arguments)
    out, err, status = Open3.capture3("git", "-C", repository, *arguments)
    assert status.success?, err
    out
  end
end
