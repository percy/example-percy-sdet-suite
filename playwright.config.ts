import { defineConfig } from '@playwright/test';

// The app under test (percy/example-percy-sdet-app) is served on :5500 by
// scripts/demo.sh — that's the "deployed" storefront the nightly run checks.
export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: 'list',
  use: {
    baseURL: process.env.APP_URL || 'http://localhost:5500',
    // Set PW_CHANNEL=chrome to use an installed Chrome instead of Playwright's Chromium.
    channel: process.env.PW_CHANNEL || undefined,
    viewport: { width: 1280, height: 900 },
  },
});
