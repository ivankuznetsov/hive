require "test_helper"

class DaemonRepairsTest < ActionDispatch::IntegrationTest
  test "repair is a resource create that queues global maintenance" do
    sign_in!
    repository = runtime_dispatch_repository
    before = repository.pending.map(&:request_id)

    post daemon_repair_path

    assert_redirected_to root_path
    request = repository.pending.find do |candidate|
      !before.include?(candidate.request_id) && candidate.trigger == "web_daemon_repair"
    end
    assert request, "repair must add a global maintenance request"
    assert_equal %w[hive daemon install --force], request.argv
    assert_equal "web_daemon_repair", request.trigger
  ensure
    repository&.remove(request.request_id) if request
  end
end
