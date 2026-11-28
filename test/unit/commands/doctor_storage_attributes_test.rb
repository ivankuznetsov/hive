require "test_helper"
require "hive/commands/doctor"
require "hive/runtime_control_plane/installation"
require "json_schemer"

class DoctorStorageAttributesTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    @root = tracked_tmp_dir
    @path = Hive::Paths.runtime_control_plane_path(@root)
  end

  def doctor(json: true, env: { "HIVE_HOME" => @root }, linux: true)
    out = StringIO.new
    inspector = Struct.new(:inspect).new([])
    command = Hive::Commands::Doctor.new(config: {}, environment: {}, project_root: nil,
                                         inspector: inspector, json: json, output: out)
    code = with_env(env) { linux ? with_linux_storage { command.call } : command.call }
    [ code, command.rows, json ? JSON.parse(out.string) : out.string ]
  end

  def test_cold_wal_database_stays_healthy_without_any_file_changes
    database = Hive::RuntimeControlPlane::Database.new(path: @path)
    database.migrate!
    database.disconnect
    assert_equal [ File.basename(@path) ], Dir.children(@root)
    before = contents
    code, rows, = doctor
    assert_equal 0, code
    assert_equal "ok", rows.find { |r| r[:label] == "runtime/sqlite" }[:status]
    assert_equal before, contents
  end

  def test_paired_wal_snapshot_reads_committed_identity_changes_without_source_writes
    database = Hive::RuntimeControlPlane::Database.new(path: @path)
    database.migrate!
    database.transaction { |db| db[:installations].delete }
    assert File.size(@path + "-wal").positive?
    before = contents
    _, rows, = doctor
    assert_includes rows.find { |r| r[:label] == "runtime/sqlite" }[:message], "installation_identity_missing"
    assert_equal before, contents
  ensure
    database&.disconnect
  end

  def test_dangling_database_reports_both_custody_and_attribute_evidence
    target = File.join(@root, "missing-target")
    File.symlink(target, @path)
    code, rows, = doctor
    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, code
    assert_equal "indeterminate", rows.find { |r| r[:label] == "runtime/sqlite-storage" }[:outcome]
    assert_includes rows.find { |r| r[:label] == "runtime/sqlite" }[:message], "database_custody_invalid"
    assert_equal target, File.readlink(@path)
    refute_path_exists target
  end

  def test_recovery_shapes_and_held_fence_fail_without_writes
    database = Hive::RuntimeControlPlane::Database.new(path: @path)
    database.migrate!
    database.disconnect
    %w[-wal -shm -journal].each do |suffix|
      File.write(@path + suffix, "", perm: 0o600)
      before = contents
      _, rows, = doctor
      assert_includes rows.find { |r| r[:label] == "runtime/sqlite" }[:message], "inspection_unavailable"
      assert_equal before, contents
      File.unlink(@path + suffix)
    end
    File.open(Hive::Paths.runtime_writer_fence_path(@root), "w", 0o600) do |fence|
      fence.flock(File::LOCK_SH)
      before = contents
      _, rows, = doctor
      assert_includes rows.find { |r| r[:label] == "runtime/sqlite" }[:message], "busy"
      assert_equal before, contents
    end
  end

  def test_fence_or_sidecar_appearing_during_copy_invalidates_private_snapshot
    database = Hive::RuntimeControlPlane::Database.new(path: @path)
    database.migrate!
    database.disconnect
    copy = IO.method(:copy_stream)
    [ Hive::Paths.runtime_writer_fence_path(@root), @path + "-wal" ].each do |late|
      changing_copy = lambda do |*args|
        File.write(late, "", perm: 0o600)
        copy.call(*args)
      end
      with_replaced_singleton_method(IO, :copy_stream, changing_copy) do
        _, rows, = doctor
        assert_includes rows.find { |r| r[:label] == "runtime/sqlite" }[:message], "inspection_unavailable"
        assert_equal [ @path, late ].sort, Dir.children(@root).map { |n| File.join(@root, n) }.sort
      end
      File.unlink(late)
    end
  end

  def test_storage_outcomes_in_both_formats
    klass = Hive::RuntimeControlPlane::StorageAttributes
    schema = JSON.parse(File.read(Hive::Schemas.schema_path("hive-doctor")))
    row_schema = JSONSchemer.schema(schema.fetch("$defs").fetch("LegacyCheck"))
    original = klass.default_runner
    [ [ :cow, "warning", "warning" ], [ :unknown, "indeterminate", "warning" ],
     [ :nocow, "healthy", "present" ], [ :ext, "not_applicable", "not_applicable" ] ].each do |mode, outcome, status|
      klass.default_runner = lambda do |name, *args|
        case name
        when "stat" then mode == :ext ? "ef53 ext2/ext3" : "9123683e btrfs"
        when "lsattr"
          mode == :unknown ? "" : "#{'-' * 20}#{mode == :nocow ? 'C' : '-'} #{args.last}"
        else flunk("unexpected #{name}")
        end
      end
      code, _, payload = doctor
      assert_equal 0, code
      row = payload.fetch("checks").find { |r| r["label"] == "runtime/sqlite-storage" }
      assert row_schema.valid?(row)
      assert_equal [ outcome, status ], row.values_at("outcome", "status")
      assert_equal @root, row.fetch("paths").first.fetch("path")
      assert_equal 0, payload.dig("summary", "legacy_failures")
      assert_equal(status == "warning" ? 1 : 0, payload.dig("summary", "warnings"))
      code, _, table = doctor(json: false)
      assert_equal 0, code
      assert_includes table, "runtime/sqlite-storage"
      case mode
      when :cow then assert_includes table, "wiki/commands/runtime.md#btrfs-nocow-migration"
      when :unknown
        assert_includes table, "could not determine NOCOW status (lsattr"
        refute_includes table, "migration"
      end
    end
    _, _, payload = doctor(env: { "HIVE_HOME" => nil, "XDG_STATE_HOME" => @root })
    assert_equal "uninitialized", payload.fetch("checks").find { |r| r["label"] == "runtime/sqlite-storage" }["outcome"]
    refute_path_exists File.join(@root, "hive")
  ensure
    klass.default_runner = original
  end

  def test_mismatches_name_the_individual_file_including_orphaned_sidecars
    database = Hive::RuntimeControlPlane::Database.new(path: @path)
    database.migrate!
    database.disconnect
    klass = Hive::RuntimeControlPlane::StorageAttributes
    original = klass.default_runner
    [ @root, @path, @path + "-wal", @path + "-shm", @path + "-journal" ].each do |affected|
      if affected.start_with?(@path + "-")
        File.unlink(@path) if File.file?(@path)
        File.write(affected, "", perm: 0o600)
      end
      klass.default_runner = lambda do |name, *args|
        next "9123683e btrfs" if name == "stat"
        "----------------#{args.last == affected ? '-' : 'C'}----- #{args.last}"
      end
      code, _, payload = doctor
      assert_equal 0, code
      row = payload.fetch("checks").find { |r| r["label"] == "runtime/sqlite-storage" }
      assert_equal [ affected ], row["paths"].select { |r| r["outcome"] == "warning" }.map { |r| r["path"] }
      assert_equal 1, payload.dig("summary", "warnings")
      _, _, table = doctor(json: false)
      assert_includes table, "#{affected}: btrfs NOCOW flag C is missing"
      File.unlink(affected) if affected.start_with?(@path + "-")
    end
  ensure
    klass.default_runner = original
  end

  def test_non_linux_diagnosis_needs_no_tools
    klass = Hive::RuntimeControlPlane::StorageAttributes
    storage = klass.new(path: @path, platform: "darwin", runner: ->(*) { flunk "unexpected probe" })
    with_replaced_singleton_method(klass, :new, -> { storage }) do
      code, rows, = doctor(linux: false)
      assert_equal 0, code
      assert_equal "not_applicable", rows.find { |r| r[:label] == "runtime/sqlite-storage" }[:outcome]
    end
  end

  def test_integrity_failure_and_mixed_storage_warning_both_render
    File.write(@path, "broken", perm: 0o600)
    klass = Hive::RuntimeControlPlane::StorageAttributes
    original = klass.default_runner
    klass.default_runner = lambda do |name, *args|
      next "9123683e btrfs" if name == "stat"
      args.last == @path ? "" : "---------------------- #{args.last}"
    end
    code, rows, payload = doctor
    assert_equal Hive::Commands::Doctor::EXIT_MISSING_SKILL, code
    assert_equal 1, payload.dig("summary", "warnings")
    assert_equal 1, payload.dig("summary", "legacy_failures")
    message = rows.find { |r| r[:label] == "runtime/sqlite-storage" }[:message]
    assert_includes message, "#{@root}: btrfs NOCOW flag C is missing"
    assert_includes message, "#{@path}: could not determine NOCOW status (lsattr"
    assert_equal "missing", rows.find { |r| r[:label] == "runtime/sqlite" }[:status]
  ensure
    klass.default_runner = original
  end

  private

  def contents
    Dir.children(@root).sort.to_h do |name|
      path = File.join(@root, name)
      [ name, [ File.stat(path).ino, File.stat(path).ctime, Digest::SHA256.file(path).hexdigest ] ]
    end
  end
end
