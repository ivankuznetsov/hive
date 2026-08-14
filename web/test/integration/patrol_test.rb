require "test_helper"

class PatrolTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!("patrol-web-app")
    sign_in!
  end

  test "patrol page exposes ordinary and architecture health without mutation controls" do
    get "/patrol", params: { project: @project }

    assert_response :success
    assert_select "a.nav-link-active[href='/patrol']", text: "Patrol"
    assert_select "select[name='project'] option[selected]", text: @project
    assert_select "h2", text: "Ordinary Patrol"
    assert_select "h2", text: "Architecture Patrol"
    assert_select "form[action='/patrol'][method='get']", 1
    assert_select "form[action*='patrol'][method='post']", 0,
                  "the findings page must remain read-only"
  end

  test "unknown patrol project is rejected" do
    get "/patrol", params: { project: "missing" }

    assert_response :not_found
  end
end
