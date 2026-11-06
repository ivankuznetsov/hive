require "test_helper"
require "hive/dependency_edit"

class DependencyEditTest < Minitest::Test
  include HiveTestHelper

  def test_plan_absence_is_preserved_and_existing_assertion_only_is_changed
    [ nil, "# Prose\n", "---\n---\n# Plan\n", "---\n# empty\n---\n", "---\ntitle: café\n---\n# Plan\n" ].each do |bytes|
      assertion, after = Hive::PlanFrontmatter.edit_dependency(bytes, "base")
      refute assertion.fetch("present")
      bytes.nil? ? assert_nil(after) : assert_equal(bytes, after)
    end
    before, after = Hive::PlanFrontmatter.edit_dependency("---\ndepends_on: old\n---\n# Plan\n", nil)
    assert before.fetch("present")
    assert_equal "---\n---\n# Plan\n", after
  end

  def test_existing_task_overlay_keeps_id_and_finds_cycles_and_all_edges
    with_tmp_dir do |root|
      folders = %w[edited base].map do |slug|
        folder = File.join(root, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: slug == "edited" ? 1 : 2, slug: slug, display_name: slug)
        folder
      end
      entries = [ { "name" => File.basename(root), "path" => root } ]
      task = Hive::Task.new(folders.first)
      assert_raises(Hive::DependencyAdmissionError) { Hive::DependencyEdit.prepare(task, value: "1", registry_entries: entries) }
      Hive::TaskMeta.rewrite(folders.last, depends_on: "edited")
      assert_raises(Hive::DependencyAdmissionError) { Hive::DependencyEdit.prepare(task, value: "base", registry_entries: entries) }
      Hive::TaskMeta.rewrite(folders.last, depends_on: nil)
      assert_raises(Hive::DependencyAdmissionError) { Hive::DependencyEdit.prepare(task, value: [ "base", "missing" ], registry_entries: entries) }
      proposal = Hive::DependencyEdit.prepare(task, value: [ "base" ], registry_entries: entries)
      assert proposal.verdict.wait?
      refute Hive::TaskMeta.read(folders.first)[:depends_on]
    end
  end

  def test_yaml_replacement_preserves_comments_unicode_and_crlf
    bytes = "title: café\r\n'depends_on': [old, older] # edge\r\nother:\r\n  x: yes\r\n"
    document = Hive::DependencyEdit::Document.new(bytes)
    assert_equal "title: café\r\n'depends_on': [\"new\"] # edge\r\nother:\r\n  x: yes\r\n", document.edit([ "new" ])
    assert_equal "title: café\r\nother:\r\n  x: yes\r\n", document.edit(nil)
  end

  def test_flow_mapping_set_clear_and_insertion
    doc = Hive::DependencyEdit::Document.new('{title: café, "depends_on": old, other: [a, b]}')
    assert_equal '{title: café, "depends_on": "new", other: [a, b]}', doc.edit("new")
    assert_equal "{title: café, other: [a, b]}", doc.edit(nil)
    assert_equal '{title: café, depends_on: "new"}', Hive::DependencyEdit::Document.new("{title: café}").edit("new")
  end

  def test_block_list_and_last_flow_entry_clear
    assert_equal "title: x\n# tail\n", Hive::DependencyEdit::Document.new("title: x\ndepends_on:\n  - old\n  - older\n# tail\n").edit(nil)
    assert_equal "{title: x}", Hive::DependencyEdit::Document.new("{title: x, depends_on: old}").edit(nil)
  end

  def test_ambiguous_yaml_is_rejected_before_mutation
    [ "a: 1\na: 2\n", "nested: {a: 1, a: 2}", "a: &x old\ndepends_on: *x", "depends_on: [", "depends_on: []" ].each do |bytes|
      assert_raises(ArgumentError) { Hive::DependencyEdit::Document.new(bytes) }
    end
  end

  def test_occurrences_preserve_singleton_list_shape
    assert_equal "base", Hive::DependencyEdit.request(references: [ "base" ], clear: false)
    assert_equal [ "base" ], Hive::DependencyEdit.request(references: [ "base", "base" ], clear: false)
    assert_nil Hive::DependencyEdit.request(references: [], clear: true)
  end

  def test_request_rejects_missing_or_conflicting_edit_options
    [ [ [], false ], [ [ "base" ], true ] ].each do |references, clear|
      error = assert_raises(ArgumentError) { Hive::DependencyEdit.request(references: references, clear: clear) }
      assert_equal "supply --depends-on (repeatable) or --clear, exclusively", error.message
    end
  end

  def test_merge_and_complex_yaml_keys_are_rejected_before_mutation
    [ "<<: old\n", "? [a, b]\n: old\n", "nested: {<<: old}\n" ].each do |bytes|
      error = assert_raises(ArgumentError) { Hive::DependencyEdit::Document.new(bytes) }
      assert_equal "ambiguous YAML mapping key", error.message
    end
  end
end
