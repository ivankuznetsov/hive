require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  setup { sign_in! }

  test "board is the default and settings can make grid the default" do
    get root_path
    assert_response :success
    assert_select ".kanban-board", 1

    patch settings_path, params: { default_view: "grid" }
    assert_redirected_to settings_path

    get root_path, params: { project: "alpha" }
    assert_response :success
    assert_select ".status-layout", 1

    get settings_path
    assert_response :success
    assert_select "select[name='default_view'] option[value='grid'][selected]"
  end

  test "settings reject unknown views" do
    patch settings_path, params: { default_view: "timeline" }

    assert_response :unprocessable_entity
  end
end
