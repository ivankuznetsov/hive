// Playwright contract for hivebox.
//
// Run with:
//   HIVEBOX_URL=http://127.0.0.1:4567 npx playwright test test/e2e/hivebox_happy_path.spec.js
//
// HIVEBOX_URL is REQUIRED. Per the project E2E rules the spec must fail loudly
// when its dependency is missing rather than skip — a CI runner without a live
// hivebox is a real failure to surface, not a condition to silently pass.
//
// Provider screens for GitHub, Claude, Codex, and Telegram require real
// accounts/tokens and are intentionally not stubbed here. The authenticated
// surfaces (status grid, /agents, /repos, /telegram forms) sit behind the
// GitHub-owner OAuth gate; there is currently NO HTTP-level test-auth seam in
// `lib/hive/web/app.rb` (the only auth path is the real GitHub OAuth callback,
// which `test/support/web_session_helper.rb` only exercises in-process via a
// fake GithubAuth + Rack::Test session cookie). A browser-driven e2e therefore
// cannot reach the authenticated surfaces without real GitHub OAuth or a new
// backend seam (e.g. a documented HIVEBOX_TEST_SESSION cookie the app honours
// in a test profile). Until that seam exists, this spec asserts the full
// unauthenticated contract: every protected route redirects to /login and never
// leaks protected content.
const { test, expect } = require("@playwright/test");

const baseURL = process.env.HIVEBOX_URL;

if (!baseURL) {
  throw new Error(
    "HIVEBOX_URL is required to run the hivebox e2e (e.g. " +
      "HIVEBOX_URL=http://127.0.0.1:4567). The spec fails loudly instead of " +
      "skipping when its live-app dependency is missing."
  );
}

// Page Object for the hivebox login gate. Encapsulates the locators and the
// navigation actions so the tests describe intent, not selectors.
class LoginPage {
  constructor(page) {
    this.page = page;
    this.githubButton = page.getByRole("button", { name: "Continue with GitHub" });
    this.statusGrid = page.locator("[data-status-grid]");
  }

  async goto(path = "/") {
    await this.page.goto(new URL(path, baseURL).toString());
  }

  async expectOnLogin() {
    await expect(this.page).toHaveURL(/\/login$/);
    await expect(this.githubButton).toBeVisible();
  }

  async expectNoProtectedContent() {
    // A redirect to /login that still rendered protected markup would be a
    // regression, so assert the absence explicitly (positive AND negative).
    await expect(this.statusGrid).toHaveCount(0);
  }
}

test.describe("hivebox unauthenticated contract", () => {
  test("fresh box requires GitHub login before status is visible", async ({ page }) => {
    const login = new LoginPage(page);
    await login.goto("/");
    await login.expectOnLogin();
    await login.expectNoProtectedContent();
  });

  test("every protected setup surface redirects to login when unauthenticated", async ({ page }) => {
    const login = new LoginPage(page);
    for (const path of ["/agents", "/repos", "/telegram"]) {
      await login.goto(path);
      await login.expectOnLogin();
      await login.expectNoProtectedContent();
    }
  });
});
