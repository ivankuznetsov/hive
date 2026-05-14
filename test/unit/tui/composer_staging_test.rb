require "test_helper"
require "hive/tui/model"
require "hive/tui/composer_staging"

class HiveTuiComposerStagingTest < Minitest::Test
  include HiveTestHelper

  def test_ensure_dir_creates_tmpdir_and_returns_updated_model
    result = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial)

    assert File.directory?(result.dir)
    assert_equal result.dir, result.model.new_idea_staging_dir
    assert_equal File.expand_path(Dir.tmpdir), result.model.new_idea_staging_tmp_root
    assert File.expand_path(result.dir).start_with?("#{result.model.new_idea_staging_tmp_root}#{File::SEPARATOR}")
  ensure
    Hive::Tui::ComposerStaging.cleanup!(
      result.dir,
      tmproot: result.model.new_idea_staging_tmp_root
    ) if result
  end

  def test_ensure_dir_reuses_existing_dir_and_returns_input_model
    with_tmp_dir do |dir|
      model = Hive::Tui::Model.initial.with(
        new_idea_staging_dir: dir,
        new_idea_staging_tmp_root: File.dirname(dir)
      )

      result = Hive::Tui::ComposerStaging.ensure_dir!(model)

      assert_equal dir, result.dir
      assert_same model, result.model
    end
  end

  def test_ensure_dir_backfills_missing_tmp_root_for_legacy_model_shape
    with_tmp_dir do |dir|
      model = Hive::Tui::Model.initial.with(new_idea_staging_dir: dir)

      result = Hive::Tui::ComposerStaging.ensure_dir!(model)

      assert_equal dir, result.dir
      assert_equal File.expand_path(Dir.tmpdir), result.model.new_idea_staging_tmp_root
    end
  end

  def test_next_label_and_path_uses_provided_number_directly
    label, path = Hive::Tui::ComposerStaging.next_label_and_path("/tmp/stage", 1)

    assert_equal "image1", label
    assert_equal "/tmp/stage/image-1.png", path
  end

  def test_next_label_and_path_uses_number_and_extension
    label, path = Hive::Tui::ComposerStaging.next_label_and_path("/tmp/stage", 3, ext: "jpg")

    assert_equal "image3", label
    assert_equal "/tmp/stage/image-3.jpg", path
  end

  def test_normalized_extension_falls_back_to_png
    assert_equal "png", Hive::Tui::ComposerStaging.normalized_extension(nil)
    assert_equal "png", Hive::Tui::ComposerStaging.normalized_extension("")
    assert_equal "jpg", Hive::Tui::ComposerStaging.normalized_extension(".JPG")
  end

  def test_write_bytes_and_cleanup
    dir = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial).dir
    path = File.join(dir, "image-1.png")

    Hive::Tui::ComposerStaging.write_bytes!(path, "png bytes".b)

    assert_equal "png bytes", File.binread(path)
    Hive::Tui::ComposerStaging.cleanup!(dir)
    refute File.exist?(dir)
  end

  def test_write_bytes_preserves_cause_class_on_failure
    err = assert_raises(Hive::Tui::ComposerStaging::WriteError) do
      Hive::Tui::ComposerStaging.write_bytes!("/no/such/dir/image-1.png", "x".b)
    end

    # The test path deterministically produces ENOENT (no/such/dir is
    # absent). Pinning the specific Errno class catches a future
    # rescue widening that swallows a class the operator-facing flash
    # depends on naming.
    assert_equal Errno::ENOENT, err.cause_class,
      "WriteError must preserve the originating Errno class (got #{err.cause_class})"
  end

  def test_copy_file
    dir = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial).dir
    with_tmp_dir do |src_dir|
      src = File.join(src_dir, "shot.png")
      dest = File.join(dir, "image-1.png")
      File.binwrite(src, "image".b)

      Hive::Tui::ComposerStaging.copy_file!(src, dest)

      assert_equal "image", File.binread(dest)
    end
  ensure
    Hive::Tui::ComposerStaging.cleanup!(dir) if dir
  end

  def test_cleanup_refuses_paths_outside_tmpdir
    # Fixed sentinel path (not `__dir__`-relative) so the assertion is
    # portable across macOS's /tmp → /private/tmp symlink semantics.
    err = assert_raises(ArgumentError) do
      Hive::Tui::ComposerStaging.cleanup!("/var/empty/not-tmp")
    end

    assert_match(/outside tmpdir/, err.message)
  end

  def test_cleanup_returns_early_on_blank_input
    # Branch coverage: `staging_dir.to_s.empty?` short-circuit must
    # NOT raise the "outside tmpdir" guard for nil/blank inputs.
    assert_nil Hive::Tui::ComposerStaging.cleanup!(nil)
    assert_nil Hive::Tui::ComposerStaging.cleanup!("")
  end

  def test_cleanup_refuses_tmpdir_root_itself
    # Branch coverage: `path == tmp` exact-equality refusal — must not
    # accidentally `rm -rf /tmp`.
    err = assert_raises(ArgumentError) do
      Hive::Tui::ComposerStaging.cleanup!(Dir.tmpdir)
    end

    assert_match(/outside tmpdir/, err.message)
  end

  def test_cleanup_uses_captured_tmp_root
    with_tmp_dir do |tmp_root|
      dir = Dir.mktmpdir("hive-tui-composer-test-", tmp_root)

      Hive::Tui::ComposerStaging.cleanup!(dir, tmproot: tmp_root)

      refute File.exist?(dir)
    end
  end
end
