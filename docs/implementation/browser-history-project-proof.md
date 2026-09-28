# Browser history project-alignment proof

The real Playwright system scenario
`PipelineFlowTest#test_browser_history_keeps_a_filtered_page_and_composer_project_aligned`
is the temporal proof for the permanent composer and URL-owned project filter.
Its ordered storyboard is:

1. Visit the grid filtered to the first project and verify both the selected
   filter and the composer's submission project.
2. Visit the second project and verify the permanent composer realigns after
   Turbo renders that page.
3. Invoke browser Back; wait for the first URL/filter and verify the composer no
   longer targets the later project.
4. Invoke browser Forward; wait for the second URL/filter and verify the
   submission target is restored.
5. Dispatch a `popstate` for a first-project history selection that has not
   rendered, then issue an explicit visit to the second project.
6. Verify the explicit visit cancels the abandoned history selection and both
   filter and composer remain aligned to the second project.

Run it with:

```sh
cd web
bundle exec ruby bin/rails test:system test/system/pipeline_flow_test.rb \
  -n '/browser history/'
```

The 2026-09-28 focused run completed in 3.942 seconds of test time (6.016
seconds wall time) with 1 run and 18 assertions, no failures, errors, or skips.
The execution environment exposes a real browser fixture but no admitted video
capture channel. The system assertion is executable temporal evidence; this
document is an ordered storyboard, not a fabricated recording.
