import { test } from '@playwright/test';
import percySnapshot from '@percy/playwright';

test.describe('storefront nightly regression', () => {
  test('home', async ({ page }) => {
    await page.goto('/index.html');
    await percySnapshot(page, 'Home');
  });

  test('shop grid', async ({ page }) => {
    await page.goto('/products.html');
    await percySnapshot(page, 'Shop');
  });

  test('product detail', async ({ page }) => {
    await page.goto('/product-1.html');
    await percySnapshot(page, 'Product Detail');
  });

  test('cart', async ({ page }) => {
    await page.goto('/cart.html');
    await percySnapshot(page, 'Cart');
  });
});
