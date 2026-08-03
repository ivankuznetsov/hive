require "test_helper"
require "hive/web/task_capture"

class WebTaskCaptureCoverageTest < Minitest::Test
  include HiveTestHelper

  def test_git_index_flag_consumer_rejects_every_bounded_invalid_shape
    consumer_class = Hive::Web::TaskCapture.const_get(:GitIndexFlagConsumer, false)

    overlong = consumer_class.new(max_entries: 2, max_record_bytes: 3)
    error = assert_raises(capture_error) { overlong.write("xxxx") }
    assert_match(/record exceeded/, error.message)

    too_many = consumer_class.new(max_entries: 1, max_record_bytes: 20)
    error = assert_raises(capture_error) { too_many.write("H one\0H two\0") }
    assert_match(/entry custody limit/, error.message)

    malformed = consumer_class.new(max_entries: 1, max_record_bytes: 20)
    error = assert_raises(capture_error) { malformed.write("malformed\0") }
    assert_match(/unsupported representation/, error.message)
  end

  def test_call_translates_provider_failures
    with_capture do |capture, source, _task_folder|
      provider_error = Hive::Web::ProjectCaptureProvider::ProviderError
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => "a" * 40 }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      capture.define_singleton_method(:select_recorder) do |_source_root|
        { kind: :project_provider, config: {} }
      end
      capture.define_singleton_method(:capture_with_provider) do |**|
        raise provider_error, "provider failed"
      end

      error = assert_raises(capture_error) { capture.call }
      assert_match(/provider failed/, error.message)
    end
  end

  def test_builtin_capture_translates_structural_failures
    source_bundle = Object.new
    source_bundle.define_singleton_method(:ensure!) { raise Errno::EIO, "bundle failed" }

    with_capture(source_bundle: source_bundle) do |capture, source, _task_folder|
      error = assert_raises(capture_error) do
        capture.send(:capture_with_builtin, source_root: source, expected_head: "a" * 40)
      end
      assert_match(/bundle failed/, error.message)
    end
  end

  def test_provider_source_identity_checks_fail_closed
    with_capture do |capture, source, _task_folder|
      file = File.join(source, "not-a-directory")
      File.write(file, "x")
      error = assert_raises(capture_error) do
        capture.send(
          :verify_provider_source!, file, "a" * 40,
          provider_executable: "bin/provider"
        )
      end
      assert_match(/owned Git worktree directory/, error.message)

      other = File.join(File.dirname(source), "other")
      FileUtils.mkdir_p(other)
      top_mismatch = task_capture(capture.task.folder)
      top_mismatch.define_singleton_method(:capture_git!) { |*| other }
      error = assert_raises(capture_error) do
        top_mismatch.send(
          :verify_provider_source!, source, "a" * 40,
          provider_executable: "bin/provider"
        )
      end
      assert_match(/does not match the Git worktree top level/, error.message)

      head_mismatch = task_capture(capture.task.folder)
      responses = [ source, "b" * 40 ]
      head_mismatch.define_singleton_method(:capture_git!) { |*| responses.shift }
      error = assert_raises(capture_error) do
        head_mismatch.send(
          :verify_provider_source!, source, "a" * 40,
          provider_executable: "bin/provider"
        )
      end
      assert_match(/does not match requirement/, error.message)

      missing = File.join(source, "missing")
      error = assert_raises(capture_error) do
        capture.send(
          :verify_provider_source!, missing, "a" * 40,
          provider_executable: "bin/provider"
        )
      end
      assert_match(/source is unavailable/, error.message)
    end
  end

  def test_provider_source_snapshot_bounds_entry_count_and_inventory_errors
    with_capture do |capture, source, _task_folder|
      File.write(File.join(source, "one"), "1")
      File.write(File.join(source, "two"), "2")
      original = Hive::Web::TaskCapture::PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES
      original_verbose = $VERBOSE
      $VERBOSE = nil
      Hive::Web::TaskCapture.send(:remove_const, :PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES)
      Hive::Web::TaskCapture.const_set(:PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES, 1)
      begin
        error = assert_raises(capture_error) do
          capture.send(:provider_source_snapshot!, source)
        end
        assert_match(/1-entry custody limit/, error.message)
      ensure
        Hive::Web::TaskCapture.send(:remove_const, :PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES)
        Hive::Web::TaskCapture.const_set(
          :PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES, original
        )
        $VERBOSE = original_verbose
      end

      error = with_replaced_singleton_method(
        Find, :find, ->(*) { raise Errno::EACCES, "denied" }
      ) do
        assert_raises(capture_error) do
          capture.send(:provider_source_snapshot!, source)
        end
      end
      assert_match(/could not be inventoried/, error.message)
    end
  end

  def test_provider_source_records_detect_identity_and_entry_type_changes
    with_capture do |capture, source, _task_folder|
      file = File.join(source, "file")
      File.binwrite(file, "before")
      original_stat = File.lstat(file)
      capture.define_singleton_method(:provider_source_file_digest!) do |path, *, **|
        File.binwrite(path, "after-change")
        "digest"
      end
      error = assert_raises(capture_error) do
        capture.send(
          :provider_source_record, file, "file", original_stat,
          deadline: Float::INFINITY
        )
      end
      assert_match(/changed while custody was inventoried/, error.message)

      target = File.join(source, "target")
      link = File.join(source, "link")
      File.write(target, "target")
      File.symlink("target", link)
      record = task_capture(capture.task.folder).send(
        :provider_source_record, link, "link", File.lstat(link),
        deadline: Float::INFINITY
      )
      refute_empty record

      fake_stat = Struct.new(
        :ftype, :mode, :uid, :gid, :ino, :size, :mtime, :ctime
      ).new("mystery", 0, Process.uid, Process.gid, 1, 0, Time.now, Time.now)
      error = assert_raises(capture_error) do
        capture.send(
          :provider_source_record, file, "file", fake_stat,
          deadline: Float::INFINITY
        )
      end
      assert_match(/unsupported mystery entry/, error.message)
    end
  end

  def test_provider_source_digest_detects_growth_and_shrinkage
    with_capture do |capture, source, _task_folder|
      file = File.join(source, "changing")
      File.binwrite(file, "ab")
      assert_raises(capture_error) do
        capture.send(
          :provider_source_file_digest!, file, 1, deadline: Float::INFINITY
        )
      end

      File.binwrite(file, "a")
      assert_raises(capture_error) do
        capture.send(
          :provider_source_file_digest!, file, 2, deadline: Float::INFINITY
        )
      end
    end
  end

  def test_capture_git_translates_custody_and_signal_failures
    with_capture do |capture, source, _task_folder|
      cases = [
        [ git_result.merge("internal_error" => "internal"), /custody failed.*internal/ ],
        [ git_result.merge("cleanup_failed" => true), /descendants could not be terminated/ ],
        [
          git_result.merge(
            "status" => {
              "success" => false, "signaled" => true,
              "exitstatus" => nil, "termsig" => 9
            }
          ),
          /failed \(signal 9\)/
        ]
      ]
      cases.each do |result, message|
        error = with_replaced_singleton_method(
          Hive::Web::ProjectCaptureProvider, :capture_command_with_custody,
          ->(**) { result }
        ) do
          assert_raises(capture_error) { capture.send(:capture_git!, source, "status") }
        end
        assert_match message, error.message
      end

      provider_error = Hive::Web::ProjectCaptureProvider::ProviderError
      error = with_replaced_singleton_method(
        Hive::Web::ProjectCaptureProvider, :capture_command_with_custody,
        ->(**) { raise provider_error, "provider boundary" }
      ) do
        assert_raises(capture_error) { capture.send(:capture_git!, source, "status") }
      end
      assert_match(/custody failed.*provider boundary/, error.message)
    end
  end

  def test_provider_media_cleanup_reports_retention_and_rolls_back_partial_publish
    output = StringIO.new
    with_capture(error: output) do |capture, source, task_folder|
      error = with_replaced_singleton_method(
        FileUtils, :rm_f, ->(*) { raise Errno::EACCES, "denied" }
      ) do
        capture.send(
          :cleanup_superseded_provider_media!, [ "/tmp/old.png" ], keep: []
        )
        output.string
      end
      assert_match(/retained superseded provider media old.png/, error)

      staging = File.join(task_folder, "staging")
      media = File.join(task_folder, "media")
      FileUtils.mkdir_p([ staging, media ])
      first_source = File.join(source, "first.png")
      first_destination = File.join(media, "first.png")
      File.binwrite(first_source, "first")
      publication = [
        {
          "source" => first_source, "destination" => first_destination,
          "manifest" => { "bytes" => 5, "sha256" => Digest::SHA256.hexdigest("first") }
        },
        {
          "source" => File.join(source, "missing.png"),
          "destination" => File.join(media, "second.png"),
          "manifest" => { "bytes" => 1, "sha256" => "a" * 64 }
        }
      ]

      assert_raises(Errno::ENOENT) do
        capture.send(:publish_provider_media!, publication, staging: staging)
      end
      refute File.exist?(first_destination)
    end
  end

  def test_manifest_budget_translates_serialization_failures
    with_capture do |capture, _source, _task_folder|
      error = assert_raises(capture_error) do
        capture.send(:validate_manifest_budget!, { "invalid" => Float::NAN })
      end
      assert_match(/could not be serialized/, error.message)
    end
  end

  private

  def capture_error
    Hive::Web::TaskCapture::CaptureError
  end

  def task_capture(task_folder, **options)
    Hive::Web::TaskCapture.new(
      task_folder: task_folder,
      environment: { "PATH" => ENV.fetch("PATH", "") },
      **options
    )
  end

  def with_capture(**options)
    Dir.mktmpdir("hive-task-capture-coverage") do |root|
      source = File.join(root, "source")
      task_folder = File.join(
        root, ".hive-state", "stages", "7-artifacts", "demo-task"
      )
      FileUtils.mkdir_p([ source, task_folder ])
      yield task_capture(task_folder, **options), source, task_folder
    end
  end

  def git_result
    {
      "stdout" => "", "stderr" => "", "internal_error" => nil,
      "cleanup_failed" => false, "stdout_consumer_error" => nil,
      "timed_out" => false, "stdout_overflow" => false,
      "stderr_overflow" => false, "leftover_processes" => false,
      "status" => {
        "success" => true, "signaled" => false,
        "exitstatus" => 0, "termsig" => nil
      }
    }
  end
end
