import { test } from '@playwright/test';
import percySnapshot from '@percy/playwright';

// The journal page carries the rotating promo strip the marketing team
// updates continuously — its copy changes between nightly runs by design.
test('journal with promo strip', async ({ page }) => {
  await page.goto('/blog.html');
  await page.evaluate(() => {
    const promos = [
      'Midsummer sale — 20% off all lighting',
      'Free shipping on orders over €150',
      'New arrivals: the Aalto ceramics collection',
      'Studio visit: behind the scenes in Copenhagen',
      'Gift cards now available',
      'Members get early access to the autumn drop',
    ];
    const pick = promos[Math.floor(Math.random() * promos.length)];
    const strip = document.createElement('div');
    strip.setAttribute('style',
      'background:#1f2933;color:#fff;text-align:center;padding:10px 0;font-size:15px;');
    strip.textContent = pick;
    document.body.prepend(strip);
  });
  await percySnapshot(page, 'Journal');
});
