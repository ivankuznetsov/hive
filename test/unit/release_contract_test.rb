require "test_helper"

class ReleaseContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  RELEASE_WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")

  def test_release_metadata_matches_runtime_version
    version = Regexp.escape(Hive::VERSION)

    assert_match(/^    hive-cli \(#{version}\)$/, read("Gemfile.lock"))
    assert_match(/^    hive-cli \(#{version}\)$/, read("web/Gemfile.lock"))
    assert_equal 1, read("CHANGELOG.md").scan(/^## #{version}$/).size
    assert_equal 1, read("README.md").scan(%r{/v#{version}/install\.sh}).size
    assert_equal 2, read("install.md").scan(%r{/v#{version}/install\.sh}).size
  end

  def test_discord_announcement_uses_supported_update_command
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    step = workflow.fetch("jobs").fetch("release-finalize").fetch("steps").find do |candidate|
      candidate["name"] == "Announce release on Discord"
    end

    refute_nil step
    assert_equal "${{ env.DISCORD_RELEASE_WEBHOOK != '' }}", step.fetch("if")
    assert_equal true, step.fetch("continue-on-error")
    assert_includes step.fetch("run"), "\\`hive update\\`"
    refute_includes step.fetch("run"), "gem install hive-cli"
  end

  def test_signed_checksum_manifest_covers_the_managed_web_bundle
    workflow = read(".github/workflows/release.yml")

    assert_match(/sha256sum hive-cli-\*\.gem hive-web-\*\.tar\.gz > SHA256SUMS/, workflow)
    assert_includes workflow, "hive-web-${version}.tar.gz"
    assert_includes workflow,
                    '--certificate-identity-regexp "^https://github\\.com/ivankuznetsov/hive/' \
                    '\\.github/workflows/release\\.yml@refs/tags/${REF_NAME}$"'
  end

  private

  def read(path)
    File.read(File.join(ROOT, path))
  end
end
