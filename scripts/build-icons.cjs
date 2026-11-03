// Rebuild platform icon sizes from the editable SVG; no generative edits.
// Requires Node.js and sharp. NODE_PATH can point at a bundled runtime.
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'App/Resources/Branding/Aitvaras.svg');
const output = path.join(root, 'App/Resources/Assets.xcassets/AppIcon.appiconset');
(async () => {
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      await sharp(source).resize(size * scale, size * scale).png().toFile(
        path.join(output, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`));
    }
  }
  console.log('Generated macOS app icon sizes from SVG.');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
