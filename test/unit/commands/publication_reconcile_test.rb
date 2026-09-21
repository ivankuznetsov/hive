require "test_helper"
require "hive/commands/publication_reconcile"
require "hive/cli"

class PublicationReconcileTest < Minitest::Test
  include HiveTestHelper

  def test_reconciles_only_the_owned_current_request_under_a_task_lock
    with_tmp_dir do |root|
      task = Struct.new(:folder, :slug, :project_root).new(root, "repair", root)
      File.write(File.join(root, "github-publication.json"), "{}")
      File.write(File.join(root, "pr-draft.json"), JSON.generate("title" => "Fix", "body" => "Tested"))
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { task }
      locked = false
      captured = nil
      request = Struct.new(:head_oid).new("a" * 40)
      controller = Object.new
      controller.define_singleton_method(:creation_base_oid) { "b" * 40 }
      controller.define_singleton_method(:reconcile_inspected!) do |actual, **values|
        captured = [ actual, values, locked, values.fetch(:revalidate).call(:final) ]
        { "url" => values.fetch(:pr_url), "head_oid" => actual.head_oid }
      end
      lock = lambda do |*_args, **_options, &block|
        locked = true
        block.call
      ensure
        locked = false
      end
      replacements = [
        [ Hive::TaskResolver, :new, ->(*) { resolver } ],
        [ Hive::Config, :load, ->(*) { {} } ],
        [ Hive::Lock, :with_task_lock, lock ],
        [ Hive::Worktree, :read_owned_pointer, ->(*, **) { { "path" => root } } ],
        [ Hive::Stages::OpenPr, :publication_request, ->(*, **) { request } ],
        [ Hive::GithubPublication::Controller, :new, ->(**) { controller } ]
      ]
      run_with_replacements(replacements) do
        output, = capture_io do
          Hive::CLI.start([ "publication-reconcile", "repair", "--project", "demo",
                            "--pr", "https://github.com/acme/demo/pull/42", "--head", "a" * 40, "--json" ])
        end
        assert_equal "a" * 40, JSON.parse(output).fetch("head_oid")
        output, = capture_io do
          Hive::Commands::PublicationReconcile.new(
            "repair", pr: "https://github.com/acme/demo/pull/42", head: "a" * 40
          ).call
        end
        assert_includes output, "repair: reconciled"
        File.delete(File.join(root, "github-publication.json"))
        assert_raises(Hive::UsageError) do
          Hive::Commands::PublicationReconcile.new("repair", pr: "url", head: "a" * 40).call
        end
      end
      assert_equal request, captured[0]
      assert_equal "a" * 40, captured[1].fetch(:inspected_head)
      assert captured[2], "recovery must hold the task lock"
      assert captured[3], "publication must revalidate the current owned request"
    end
  end

  private

  def run_with_replacements(rows, &block)
    return block.call if rows.empty?
    with_replaced_singleton_method(*rows.first) { run_with_replacements(rows.drop(1), &block) }
  end
end
