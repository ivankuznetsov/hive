require "test_helper"

class RepositoryTest < ActiveSupport::TestCase
  ProcessStatus = Data.define(:successful) do
    def success? = successful
  end

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

  test "failed clone removes its partial target and tempfile" do
    root = Pathname(Dir.mktmpdir("hive-repository-clone-failure"))
    repository = Repository.new(source: "ivankuznetsov/hive", root: root.to_s)
    log_path = root.join("clone.log")
    spawns = []
    spawn = lambda do |env, *argv, **options|
      spawns << [ env, argv, options ]
      FileUtils.mkdir_p(repository.path)
      File.write(options.fetch(:out), "permission denied")
      12_345
    end
    wait = ->(pid, flags = nil) { [ pid, ProcessStatus.new(false) ] if flags }
    tempfile = ->(*) { File.open(log_path, File::RDWR | File::CREAT | File::TRUNC, 0o600) }

    with_replaced_singleton_method(Tempfile, :create, tempfile) do
      with_replaced_singleton_method(Process, :spawn, spawn) do
        with_replaced_singleton_method(Process, :waitpid2, wait) do
          error = assert_raises(Hive::Error) do
            repository.register!(setup: InitSetup.new({}))
          end

          assert_equal "clone failed: permission denied", error.message
        end
      end
    end

    assert_equal 1, spawns.size
    assert_equal({}, spawns.first.fetch(0))
    assert_equal [ "gh", "repo", "clone", repository.source, repository.path ], spawns.first.fetch(1)
    assert spawns.first.fetch(2).fetch(:pgroup)
    refute_path_exists repository.path
    refute_path_exists log_path
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  test "timed out clone kills its process group and removes partial state" do
    root = Pathname(Dir.mktmpdir("hive-repository-clone-timeout"))
    repository = Repository.new(source: "ivankuznetsov/hive", root: root.to_s)
    log_path = root.join("clone.log")
    signals = []
    waits = []
    expired = Repository::CLONE_TIMEOUT_SEC + 1.0
    times = [ 0.0, expired ]
    spawn = lambda do |_env, *_argv, **options|
      FileUtils.mkdir_p(repository.path)
      File.write(options.fetch(:out), "still cloning")
      54_321
    end
    clock = -> { times.shift || expired }
    wait = lambda do |pid, flags = nil|
      waits << [ pid, flags ]
      flags ? nil : [ pid, ProcessStatus.new(false) ]
    end
    kill = ->(signal, pid) { signals << [ signal, pid ] }
    tempfile = ->(*) { File.open(log_path, File::RDWR | File::CREAT | File::TRUNC, 0o600) }

    with_replaced_singleton_method(Tempfile, :create, tempfile) do
      with_replaced_singleton_method(Process, :spawn, spawn) do
        with_replaced_singleton_method(repository, :monotonic_now, clock) do
          with_replaced_singleton_method(Process, :waitpid2, wait) do
            with_replaced_singleton_method(Process, :kill, kill) do
              error = assert_raises(Hive::Error) do
                repository.register!(setup: InitSetup.new({}))
              end

              assert_match "clone timed out after #{Repository::CLONE_TIMEOUT_SEC}s", error.message
            end
          end
        end
      end
    end

    assert_equal [ [ "KILL", -54_321 ] ], signals
    assert_equal [ [ 54_321, Process::WNOHANG ], [ 54_321, nil ] ], waits
    refute_path_exists repository.path
    refute_path_exists log_path
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end
end
