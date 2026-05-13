require "test_helper"
require "hive/tui/model"
require "hive/tui/composer_staging"

class HiveTuiComposerStagingTest < Minitest::Test
  include HiveTestHelper

  def test_ensure_dir_creates_tmpdir_and_returns_updated_model
    dir, new_model = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial)

    assert File.directory?(dir)
    assert_equal dir, new_model.new_idea_staging_dir
    assert File.expand_path(dir).start_with?("#{File.expand_path(Dir.tmpdir)}#{File::SEPARATOR}")
  ensure
    Hive::Tui::ComposerStaging.cleanup!(dir) if dir
  end

  def test_ensure_dir_reuses_existing_dir_without_model_change
    with_tmp_dir do |dir|
      model = Hive::Tui::Model.initial.with(new_idea_staging_dir: dir)

      returned_dir, new_model = Hive::Tui::ComposerStaging.ensure_dir!(model)

      assert_equal dir, returned_dir
      assert_nil new_model
    end
  end

  def test_next_label_and_path_uses_one_indexed_image_filename
    label, path = Hive::Tui::ComposerStaging.next_label_and_path("/tmp/stage", 0)

    assert_equal "image1", label
    assert_equal "/tmp/stage/image-1.png", path
  end

  def test_next_label_and_path_uses_count_and_extension
    label, path = Hive::Tui::ComposerStaging.next_label_and_path("/tmp/stage", 2, ext: "jpg")

    assert_equal "image3", label
    assert_equal "/tmp/stage/image-3.jpg", path
  end

  def test_normalized_extension_falls_back_to_png
    assert_equal "png", Hive::Tui::ComposerStaging.normalized_extension(nil)
    assert_equal "png", Hive::Tui::ComposerStaging.normalized_extension("")
    assert_equal "jpg", Hive::Tui::ComposerStaging.normalized_extension(".JPG")
  end

  def test_write_bytes_and_cleanup
    dir, = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial)
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

    assert err.cause_class, "WriteError must carry the original Errno class"
    assert err.cause_class <= SystemCallError,
      "cause_class must be a SystemCallError subclass (got #{err.cause_class})"
  end

  def test_copy_file
    dir, = Hive::Tui::ComposerStaging.ensure_dir!(Hive::Tui::Model.initial)
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
end
