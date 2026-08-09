import sharp from 'sharp';
import pngToIco from 'png-to-ico';
import { writeFileSync } from 'node:fs';

const SRC = 'slapstat-logo-source.png';
const meta = await sharp(SRC).metadata();
const W = meta.width;
const H = meta.height;
console.log('source', W, 'x', H);

await sharp(SRC).trim({ threshold: 10 }).png().toFile('slapstat-logo.png');
const hm = await sharp('slapstat-logo.png').metadata();
console.log('header logo', hm.width, 'x', hm.height);

const cropped = await sharp(SRC)
  .extract({
    left: Math.round(W * 0.05),
    top: Math.round(H * 0.36),
    width: Math.round(W * 0.29),
    height: Math.round(H * 0.26),
  })
  .png()
  .toBuffer();
const iconTight = await sharp(cropped).trim({ threshold: 10 }).png().toBuffer();
const im = await sharp(iconTight).metadata();
console.log('icon', im.width, 'x', im.height);
await sharp(iconTight).toFile('slapstat-icon.png');

async function squareIcon(size, name) {
  const pad = Math.round(size * 0.15);
  const inner = size - pad * 2;
  const icon = await sharp(iconTight)
    .resize(inner, inner, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .toBuffer();
  const radius = Math.round(size * 0.22);
  const sq = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><rect width="${size}" height="${size}" rx="${radius}" fill="#FFFFFF"/></svg>`,
  );
  await sharp({ create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: sq }, { input: icon, gravity: 'center' }])
    .png()
    .toFile(name);
  console.log('wrote', name);
}

for (const [s, n] of [
  [512, 'icon-512.png'],
  [192, 'icon-192.png'],
  [180, 'apple-touch-icon.png'],
  [48, 'favicon-48.png'],
  [32, 'favicon-32.png'],
  [16, 'favicon-16.png'],
])
  await squareIcon(s, n);

const ico = await pngToIco(['favicon-16.png', 'favicon-32.png', 'favicon-48.png']);
writeFileSync('favicon.ico', ico);
console.log('wrote favicon.ico');
