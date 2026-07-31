require "test_helper"
require "hive/modules/migration/trusted_qualification_control"

class ModulesMigrationTrustedQualificationControlTest <
    Minitest::Test
  CONTROL =
    Hive::Modules::Migration::TrustedQualificationControl

  def test_local_control_is_typed_but_never_qualifying
    control = CONTROL.from_h(
      payload(
        "trust_scope" => "local",
        "ref" => nil
      ),
      checkout_root: "/fixture/control"
    )

    assert_equal "/fixture/control", control.checkout_root
    assert_equal false, control.trusted_remote?
    assert_equal false, control.qualifying_for?("c" * 40)
    assert_equal(
      [ "qualification_control_untrusted" ],
      control.qualification_issues("c" * 40)
    )
    assert control.payload.frozen?
    assert control.payload.fetch("catalog").frozen?
  end

  def test_trusted_remote_control_requires_main_provenance
    control = CONTROL.from_h(
      payload(
        "trust_scope" => "trusted_remote",
        "ref" => "refs/heads/main",
        "provenance" => {
          "workflow_path" =>
            ".github/workflows/patrol-qualification.yml",
          "workflow_sha" => "1" * 40,
          "run_id" => 123,
          "run_attempt" => 2,
          "action_lock_sha256" => "b" * 64
        }
      ),
      checkout_root: "/fixture/control"
    )

    assert control.trusted_remote?
    assert control.qualifying_for?("c" * 40)
    assert_empty control.qualification_issues("c" * 40)
  end

  def test_same_candidate_control_is_nonqualifying
    control = CONTROL.from_h(
      payload(
        "trust_scope" => "trusted_remote",
        "ref" => "refs/heads/main",
        "commit_sha" => "c" * 40,
        "provenance" => {
          "workflow_path" =>
            ".github/workflows/patrol-qualification.yml",
          "workflow_sha" => "c" * 40,
          "run_id" => 123,
          "run_attempt" => 1,
          "action_lock_sha256" => "b" * 64
        }
      ),
      checkout_root: "/fixture/control"
    )

    assert_equal false, control.qualifying_for?("c" * 40)
    assert_equal(
      [ "qualification_control_not_independent" ],
      control.qualification_issues("c" * 40)
    )
  end

  def test_rejects_self_declared_remote_control_without_provenance
    error = assert_raises(Hive::ConfigError) do
      CONTROL.from_h(
        payload(
          "trust_scope" => "trusted_remote",
          "ref" => "refs/heads/main"
        ),
        checkout_root: "/fixture/control"
      )
    end

    assert_equal(
      "patrol qualification trusted control is malformed",
      error.message
    )
  end

  def test_rejects_trusted_remote_control_from_a_floating_or_foreign_ref
    value = payload(
      "trust_scope" => "trusted_remote",
      "ref" => "refs/heads/feature",
      "provenance" => {
        "workflow_path" =>
          ".github/workflows/patrol-qualification.yml",
        "workflow_sha" => "1" * 40,
        "run_id" => 123,
        "run_attempt" => 1,
        "action_lock_sha256" => "b" * 64
      }
    )

    assert_raises(Hive::ConfigError) do
      CONTROL.from_h(
        value,
        checkout_root: "/fixture/control"
      )
    end
  end

  def test_rejects_values_that_only_stringify_as_valid_identity
    [
      [ "commit_sha", Integer("1" * 40) ],
      [ "tree_sha", Integer("2" * 40) ],
      [ "repository", :"github.com/example/hive" ],
      [ "harness_manifest_sha256", Integer("4" * 64) ]
    ].each do |key, value|
      assert_raises(Hive::ConfigError, key) do
        CONTROL.from_h(
          payload(key => value),
          checkout_root: "/fixture/control"
        )
      end
    end

    assert_raises(Hive::ConfigError) do
      CONTROL.from_h(
        payload,
        checkout_root: Pathname.new("/fixture/control")
      )
    end
  end

  private

  def payload(overrides = {})
    {
      "repository" => "github.com/example/hive",
      "ref" => nil,
      "commit_sha" => "1" * 40,
      "tree_sha" => "2" * 40,
      "trust_scope" => "local",
      "catalog" => {
        "ref" =>
          "test/e2e/fixtures/patrol_qualification/catalog.json",
        "sha256" => "3" * 64
      },
      "harness_manifest_sha256" => "4" * 64,
      "provenance" => {
        "workflow_path" => nil,
        "workflow_sha" => nil,
        "run_id" => nil,
        "run_attempt" => nil,
        "action_lock_sha256" => nil
      }
    }.merge(overrides)
  end
end
