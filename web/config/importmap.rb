# Pin npm packages by running ./bin/importmap

pin "application"
pin "status_stream_source"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

pin "lib/copy_task_reference", to: "lib/copy_task_reference.js"

pin "lib/diff_viewer", to: "lib/diff_viewer.js"
# Loaded on demand by lib/diff_viewer only when a patch is on the page.
pin "lib/diff_renderer", to: "lib/diff_renderer.js", preload: false
