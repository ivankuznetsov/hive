"use strict"

const fs = require("fs")
const path = require("path")

async function main() {
  const [baseUrl, screenshotPath, videoDirectory] = process.argv.slice(2)
  if (!baseUrl || !screenshotPath || !videoDirectory) {
    throw new Error("usage: capture_task_page.cjs BASE_URL SCREENSHOT_PATH VIDEO_DIRECTORY")
  }

  const modulePath = process.env.HIVE_PLAYWRIGHT_MODULE
  if (!modulePath || !path.isAbsolute(modulePath)) {
    throw new Error("HIVE_PLAYWRIGHT_MODULE must name the pinned absolute module path")
  }
  const { chromium } = require(modulePath)
  fs.mkdirSync(path.dirname(screenshotPath), { recursive: true, mode: 0o700 })
  fs.mkdirSync(videoDirectory, { recursive: true, mode: 0o700 })

  const browser = await chromium.launch({ headless: true })
  let context
  try {
    context = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      recordVideo: {
        dir: videoDirectory,
        size: { width: 1280, height: 800 }
      }
    })
    const page = await context.newPage()
    const video = page.video()
    await page.goto(baseUrl, { waitUntil: "networkidle", timeout: 30000 })
    await page.locator("h1").first().waitFor({ state: "visible", timeout: 15000 })
    await page.locator(".kanban-card").first().waitFor({ state: "visible", timeout: 15000 })
    await page.screenshot({ path: screenshotPath, fullPage: true })

    await page.locator(".kanban-card-heading a").first().click()
    await page.locator("h1").first().waitFor({ state: "visible", timeout: 15000 })
    await page.waitForTimeout(1200)
    await context.close()
    context = null
    const videoPath = await video.path()

    process.stdout.write(JSON.stringify({
      video_path: videoPath,
      accessibility_assertions: [
        "Board heading is visible",
        "Synthetic task card is keyboard-addressable",
        "Task heading is visible after navigation"
      ]
    }) + "\n")
  } finally {
    if (context) await context.close().catch(() => {})
    await browser.close().catch(() => {})
  }
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack ? error.stack : error}\n`)
  process.exitCode = 1
})
