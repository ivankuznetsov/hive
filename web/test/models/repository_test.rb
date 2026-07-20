require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  test "derives a safe local name from each accepted source shape" do
    root = "/tmp/hive-repository-model"

    assert_equal "hive", Repository.new(source: "ivankuznetsov/hive", root:).name
    assert_equal "hive", Repository.new(source: "https://github.com/ivankuznetsov/hive.git", root:).name
    assert_equal "hive", Repository.new(source: "git@github.com:ivankuznetsov/hive.git", root:).name
  end

  test "normalizes a supplied local name to one path component" do
    repository = Repository.new(source: "ivankuznetsov/hive", name: "../local-hive", root: "/repos")

    assert_equal "local-hive", repository.name
    assert_equal "/repos/local-hive", repository.path
  end

  test "rejects empty, non-GitHub, and option-shaped sources" do
    assert_raises(Hive::Error) { Repository.new(source: "") }
    assert_raises(Hive::Error) { Repository.new(source: "https://evil.example/x/y") }
    assert_raises(Hive::Error) { Repository.new(source: "--upload-pack=/bin/sh") }
  end

  test "refuses a symlinked target before setup can leave the repos root" do
    root = Pathname(Dir.mktmpdir("hive-repository-root"))
    outside = Pathname(Dir.mktmpdir("hive-repository-outside"))
    File.symlink(outside, root.join("hive"))
    repository = Repository.new(source: "ivankuznetsov/hive", root: root.to_s)

    error = assert_raises(Hive::Error) do
      repository.register!(setup: InitSetup.new({}))
    end

    assert_match "not a directory", error.message
    assert root.join("hive").symlink?
  ensure
    FileUtils.remove_entry(root) if root&.exist?
    FileUtils.remove_entry(outside) if outside&.exist?
  end
end
