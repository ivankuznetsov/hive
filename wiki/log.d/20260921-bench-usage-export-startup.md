---
title: Keep startup failures visible and make sealed usage export loadable
date: 2026-09-21
---

The sealed controller mounted token_report.rb and pricing.rb, but pricing eagerly
required an unmounted model_family.rb. The EXIT exporter therefore failed before
it could write even an unavailable receipt. TokenReport now loads pricing only
when pricing is requested, keeping native usage export independent of the price
catalog. An isolated-loader regression and a network-disabled sealed-image smoke
test verify that an empty native store exports an available empty model mapping.

Cell assembly now classifies stage execution before reading usage. Missing usage
still raises UsageUnavailable for both failed startup and successful paid cells;
the error additionally preserves the stage classification, typed stage markers,
and stderr artifact path. Raw stderr is not copied, unknown usage is not fabricated
as zero, and preserved candidate patches are not discarded.
