// Manual-gated Playwright contract for hivebox.
//
// Run with:
//   HIVEBOX_URL=http://127.0.0.1:4567 npx playwright test test/e2e/hivebox_happy_path.spec.js
//
// Provider screens for GitHub, Claude, Codex, and Telegram require real
// accounts/tokens and are intentionally not stubbed here.
const { test, expect } = require("@playwright/test");

const baseURL = process.env.HIVEBOX_URL;

test.describe("hivebox happy path", () => {
  test.skip(!baseURL, "set HIVEBOX_URL to run against a live hivebox container");

  test("fresh box requires GitHub login before status is visible", async ({ page }) => {
    await page.goto(baseURL);
    await expect(page).toHaveURL(/\/login$/);
    await expect(page.getByRole("link", { name: "Continue with GitHub" })).toBeVisible();
  });

  test("authenticated operator can reach setup surfaces", async ({ page }) => {
    test.skip(true, "complete real GitHub OAuth manually, then enable this assertion block");
    await page.goto(`${baseURL}/agents`);
    await expect(page.getByRole("heading", { name: "Agents" })).toBeVisible();
    await page.goto(`${baseURL}/repos`);
    await expect(page.getByRole("heading", { name: "Repos" })).toBeVisible();
    await page.goto(`${baseURL}/telegram`);
    await expect(page.getByRole("heading", { name: "Telegram" })).toBeVisible();
  });
});
