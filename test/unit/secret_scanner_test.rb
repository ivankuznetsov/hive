require "test_helper"
require "hive/secret_scanner"
require "hive/gh"

class SecretScannerTest < Minitest::Test
  include HiveTestHelper

  def test_text_scan_detects_a_secret_after_four_megabytes_without_echoing_it
    assert Hive::SecretScanner.match?("ordinary text\n" * 400_000 + token)
    refute Hive::SecretScanner.match?("operator.password = password\n", path: "setup.rb")
    assert Hive::SecretScanner.match?("\0#{token}\0", path: "screenshot.png")
  end

  def test_missing_scanner_is_unavailable_not_clean
    with_replaced_singleton_method(Open3, :capture3, ->(*) { raise Errno::ENOENT }) do
      error = assert_raises(Hive::SecretScanner::Unavailable) { Hive::SecretScanner.match?(token) }
      refute_includes error.message, token
    end
  end

  def test_scanner_errors_and_malformed_reports_fail_closed_without_echoing_output
    secret = token
    [ [ 1, token ], [ 0, "not json" ], [ 0, "{}" ], [ 42, "[]" ], [ 42, "[{}]" ], [ 42, "[null]" ] ].each do |code, output|
      status = Hive::Gh::CommandStatus.new(exitstatus: code)
      with_replaced_singleton_method(Open3, :capture3, ->(*) { [ output, secret, status ] }) do
        error = assert_raises(Hive::SecretScanner::Unavailable) { Hive::SecretScanner.scan("test") }
        refute_includes error.message, token
      end
    end
  end

  def test_git_scan_covers_removed_secrets_and_ignores_repository_suppressions
    with_tmp_dir do |repo|
      run!("git", "init", "-b", "main", "--quiet", repo)
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      File.write(File.join(repo, "base.txt"), "base\n")
      base = commit(repo)
      File.write(File.join(repo, "secret.txt"), "token=#{token} # betterleaks:allow\n")
      File.write(File.join(repo, ".betterleaks.toml"), "prefilter = 'true'\n")
      leaked = commit(repo)
      File.write(File.join(repo, ".betterleaksignore"), "#{leaked}:secret.txt:github-pat:1\n")
      File.write(File.join(repo, "secret.txt"), "removed\n")
      File.binwrite(File.join(repo, "image.png"), "\0#{token}\0")
      head = commit(repo)

      assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head)
      assert Hive::SecretScanner.git_match?(repo, base_oid: leaked, head_oid: head),
             "binary-only additions must be scanned even when image files are normally skipped"
      refute Hive::SecretScanner.git_match?(repo, base_oid: head, head_oid: head)
      assert_raises(Hive::SecretScanner::Unavailable) do
        Hive::SecretScanner.git_match?(repo, base_oid: "f" * 40, head_oid: head)
      end
      assert_raises(Hive::SecretScanner::Unavailable) do
        Hive::SecretScanner.git_match?(repo, base_oid: "--help", head_oid: head)
      end
    end
  end

  private

  def token
    "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
  end

  def commit(repo)
    run!("git", "-C", repo, "add", ".")
    run!("git", "-C", repo, "commit", "-m", "Test change", "--quiet")
    run!("git", "-C", repo, "rev-parse", "HEAD").strip
  end
end
