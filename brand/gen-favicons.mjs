import sharp from 'sharp';
import pngToIco from 'png-to-ico';
import { writeFileSync } from 'node:fs';

const FAVICON = 'favicon.svg';
const APP = 'slapstat-app-icon.svg';

async function png(src, size, name) {
  await sharp(src, { density: 512 }).resize(size, size).png().toFile(name);
  console.log('wrote', name);
}

await png(FAVICON, 16, 'favicon-16.png');
await png(FAVICON, 32, 'favicon-32.png');
await png(FAVICON, 48, 'favicon-48.png');
await png(APP, 180, 'apple-touch-icon.png');
await png(APP, 192, 'icon-192.png');
await png(APP, 512, 'icon-512.png');

const ico = await pngToIco(['favicon-16.png', 'favicon-32.png', 'favicon-48.png']);
writeFileSync('favicon.ico', ico);
console.log('wrote favicon.ico');
