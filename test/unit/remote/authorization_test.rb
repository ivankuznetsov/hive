# frozen_string_literal: true

require "test_helper"
require "hive/remote/authorization"

class RemoteAuthorizationTest < Minitest::Test
  def test_named_grant_is_bound_to_current_registration
    Dir.mktmpdir do |root|
      project = { "name" => "demo", "path" => root, "hive_state_path" => root,
                  "registration_id" => "one", "repository_identity" => "repo" }
      token = { "id" => "public", "scopes" => ["create"], "all_projects" => false,
                "projects" => [{ "name" => "demo", "fingerprint" => Hive::Remote::Authorization.fingerprint(project) }] }
      authorization = Hive::Remote::Authorization.new(token: token, installation_id: "installation", projects: -> { [project] })
      assert_equal project, authorization.project!("demo")
      assert_equal "installation:installation:token:public", authorization.principal
      assert authorization.scope!("create")
      assert_raises(Hive::Remote::Error) { authorization.scope!("read") }
      assert_raises(Hive::Remote::Error) { authorization.project!("../demo") }
      changed = project.merge("registration_id" => "two")
      denied = Hive::Remote::Authorization.new(token: token, installation_id: "installation", projects: -> { [changed] })
      assert_empty denied.projects
      assert_equal 404, assert_raises(Hive::Remote::Error) { denied.project!("demo") }.status
      removed = Hive::Remote::Authorization.new(token: token, installation_id: "installation", projects: -> { [] })
      assert_empty removed.projects
    end
  end

  def test_all_project_grant_and_scope_independence
    project = { "name" => "demo" }
    token = { "id" => "public", "scopes" => ["answer"], "all_projects" => true, "projects" => [] }
    auth = Hive::Remote::Authorization.new(token: token, installation_id: "installation", projects: -> { [project] })
    assert_equal [project], auth.projects
    assert auth.scope!("answer")
    %w[read create act].each { |scope| assert_equal 403, assert_raises(Hive::Remote::Error) { auth.scope!(scope) }.status }
  end
end
