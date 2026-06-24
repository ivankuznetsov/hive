require "test_helper"
require "hive/screenote/secure_file"

class ScreenoteSecureFileTest < Minitest::Test
  include HiveTestHelper

  def test_write_json_writes_pretty_json_at_mode_0600
    with_tmp_dir do |dir|
      path = File.join(dir, "nested", "secret.json")

      result = Hive::Screenote::SecureFile.write_json(path, "token" => "bearer")

      assert_equal path, result
      assert_equal({ "token" => "bearer" }, JSON.parse(File.read(path)))
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_write_json_unlinks_the_partial_secret_file_when_chmod_fails
    # The file already holds the secret (a bearer token / OAuth credential) by
    # the time chmod runs; a chmod failure must not orphan a 0600 secret on
    # disk. write_json unlinks the partial file before re-raising the original
    # error so the caller still sees the real failure.
    with_tmp_dir do |dir|
      path = File.join(dir, "secret.json")

      with_replaced_singleton_method(File, :chmod, ->(*) { raise Errno::EPERM, "operation not permitted" }) do
        assert_raises(Errno::EPERM) do
          Hive::Screenote::SecureFile.write_json(path, "token" => "bearer")
        end
      end

      refute File.exist?(path), "a chmod failure must not leave the partial secret file on disk"
    end
  end
end
