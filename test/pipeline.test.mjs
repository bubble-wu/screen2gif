import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ffmpeg, ffprobe, normalizeCrop, watermarkLayout } from '../lib/video.mjs';

const root = await mkdtemp(join(tmpdir(), 's2g-tests-'));
const cli = fileURLToPath(new URL('../bin/screen2gif', import.meta.url));
const mock = fileURLToPath(new URL('./fixtures/mock-capture.cjs', import.meta.url));
after(() => execFileSync('/usr/bin/trash', [root]));
const w = 160, h = 120;
function makeVideo(name, count, fps, pixel) {
  const input = Buffer.alloc(w * h * 3 * count);
  for (let n = 0; n < count; n++) for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    input.set(pixel(n, x, y), ((n * h + y) * w + x) * 3);
  }
  const path = join(root, name + '.mkv');
  execFileSync(ffmpeg, ['-v', 'error', '-y', '-f', 'rawvideo', '-pixel_format', 'rgb24',
    '-video_size', `${w}x${h}`, '-framerate', String(fps), '-i', 'pipe:0', '-c:v', 'ffv1', path], { input });
  return path;
}
const normal = makeVideo('normal', 90, 30, n => n < 30 ? [255, 0, 0] : n < 60 ? [0, 255, 0] : [0, 0, 255]);
function convert(input, name, args = [], env = process.env) {
  const output = join(root, name + '.gif');
  const result = execFileSync(cli, ['convert', input, '-o', output, '--json', ...args], { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(result);
}
function colors(gif) {
  const buffer = execFileSync(ffmpeg, ['-v', 'error', '-i', gif, '-vf', 'scale=1:1', '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
  return Array.from({ length: buffer.length / 3 }, (_, i) => [...buffer.subarray(i * 3, i * 3 + 3)]);
}
function near(color, expected) { return color.every((value, i) => Math.abs(value - expected[i]) < 20); }

test('quick final state survives rate limiting, with and without palette', () => {
  const input = makeVideo('quick', 60, 30, n => n === 0 ? [0, 0, 0] : [255, 255, 255]);
  for (const palette of [true, false]) {
    const result = convert(input, `quick-${palette}`, ['--crop', 'off', ...(palette ? [] : ['--no-palette'])]);
    const actual = colors(result.gif);
    assert(near(actual[0], [0, 0, 0]));
    assert(near(actual.at(-1), [255, 255, 255]));
    assert.equal(result.keyframes, 2);
  }
});

test('a change on the very last source frame survives', () => {
  const input = makeVideo('last', 2, 30, n => n ? [255, 255, 255] : [0, 0, 0]);
  const result = convert(input, 'last', ['--crop', 'off']);
  assert(near(colors(result.gif).at(-1), [255, 255, 255]));
});

test('crop includes both early and later motion', () => {
  const input = makeVideo('early', 6, 5, (n, x, y) => {
    const left = n === 1 && x >= 8 && x < 40 && y >= 20 && y < 52;
    const right = n >= 3 && n % 2 && x >= 110 && x < 142 && y >= 70 && y < 102;
    return left || right ? [255, 255, 255] : [0, 0, 0];
  });
  const { crop } = convert(input, 'early');
  assert(crop.x <= 8 && crop.y <= 20);
  assert(crop.x + crop.w >= 142 && crop.y + crop.h >= 102);
});

test('one transition still yields a useful automatic crop', () => {
  const input = makeVideo('one-change', 2, 5, (n, x, y) => n && x >= 40 && x < 80 && y >= 30 && y < 70 ? [255, 255, 255] : [0, 0, 0]);
  const { crop } = convert(input, 'one-change');
  assert(crop && crop.x <= 40 && crop.y <= 30 && crop.x + crop.w >= 80 && crop.y + crop.h >= 70);
});

test('frame caps preserve final state; cap one explicitly keeps final state', () => {
  for (const cap of [1, 2]) {
    const result = convert(normal, `cap-${cap}`, ['--crop', 'off', '--max-frames', String(cap)]);
    const actual = colors(result.gif);
    assert.equal(result.keyframes, cap);
    assert(near(actual.at(-1), [0, 0, 255]));
    if (cap === 2) assert(near(actual[0], [255, 0, 0]));
  }
});

test('static input converts without a bogus crop', () => {
  const input = makeVideo('static', 5, 5, () => [255, 0, 0]);
  const result = convert(input, 'static');
  assert.equal(result.crop, null);
  assert.equal(result.keyframes, 1);
});

test('quality widths preserve original pixels or downscale without upscaling small regions', () => {
  const large = join(root, 'quality-source.mkv');
  execFileSync(ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i',
    'testsrc2=size=1920x1080:rate=2:duration=1', '-c:v', 'ffv1', large]);
  for (const [width, height] of [[0, 1080], [1440, 810], [720, 406]]) {
    const result = convert(large, `quality-${width}`, ['--width', String(width), '--crop', 'off']);
    const info = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries',
      'stream=width,height', '-of', 'json', result.gif]));
    assert.equal(info.streams[0].width, width || 1920);
    assert.equal(info.streams[0].height, height);
  }
  const small = convert(normal, 'small-clear', ['--width', '1440', '--crop', 'off']);
  const info = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries',
    'stream=width,height', '-of', 'json', small.gif]));
  assert.deepEqual(info.streams[0], { width: w, height: h });
});

test('crop normalization retains zero origin and stays inside odd-sized sources', () => {
  assert.deepEqual(normalizeCrop({ x: 0, y: 0, w: 160, h: 40 }, 160, 120, 0), { x: 0, y: 0, w: 160, h: 40 });
  const r = normalizeCrop({ x: 145, y: 95, w: 16, h: 26 }, 161, 121, 10);
  assert(r.x >= 0 && r.y >= 0 && r.x + r.w <= 161 && r.y + r.h <= 121);
});

test('JSON statistics describe encoded GIF; palette never overwrites sibling files', async () => {
  const neighbor = join(root, 'stats.gif.palette.png');
  await writeFile(neighbor, 'user-owned');
  const result = convert(normal, 'stats', ['--crop', 'off']);
  const info = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries', 'stream=nb_frames:format=duration', '-of', 'json', result.gif]));
  assert.equal(result.frames, Number(info.streams[0].nb_frames));
  assert.equal(result.gifDuration, Number(info.format.duration));
  assert.equal(await readFile(neighbor, 'utf8'), 'user-owned');
});

test('quoted paths in TMPDIR and output directories work', async () => {
  const scratch = join(root, "it's a temp dir");
  await mkdir(scratch);
  const result = convert(normal, 'spaces', ['--crop', 'off'], { ...process.env, TMPDIR: scratch });
  assert((await stat(result.gif)).size > 0);
});

test('watermark fits the final canvas, including tiny and narrow crops', () => {
  for (const [width, height] of [[1440, 810], [40, 200], [400, 20], [2, 2]]) {
    const mark = watermarkLayout({ width: 1800, height: 48 }, { width, height });
    assert(mark.width > 0 && mark.height > 0);
    assert(mark.width + 2 * mark.margin <= width);
    assert(mark.height + 2 * mark.margin <= height);
  }
});

test('watermark appears on every final frame after crop/resize, without changing timing', () => {
  const overlay = join(root, "text emoji's overlay.png");
  execFileSync(ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i',
    'color=white@0.48:size=80x20,format=rgba', '-frames:v', '1', overlay]);
  for (const palette of [true, false]) {
    const args = ['--crop', '20,10,120,100', '--width', '80', ...(palette ? [] : ['--no-palette'])];
    const plain = convert(normal, `plain-${palette}`, args);
    const marked = convert(normal, `marked-${palette}`, [...args, '--watermark-overlay', overlay]);
    assert.equal(marked.gifDuration, plain.gifDuration);
    assert.equal(marked.frames, plain.frames);
    assert.equal(marked.keyframes, plain.keyframes);
    assert.deepEqual(marked.crop, plain.crop);
    const info = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries',
      'stream=width,height', '-of', 'json', marked.gif])).streams[0];
    const frameBytes = info.width * info.height * 3;
    const layout = watermarkLayout({ width: 80, height: 20 }, info);
    const decode = path => execFileSync(ffmpeg, ['-v', 'error', '-i', path, '-fps_mode',
      'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
    const before = decode(plain.gif), after = decode(marked.gif);
    assert.equal(after.length, before.length);
    for (let frame = 0; frame < marked.frames; frame++) {
      let changed = 0;
      for (let y = 0; y < info.height; y++) for (let x = 0; x < info.width; x++) {
        const offset = frame * frameBytes + (y * info.width + x) * 3;
        const delta = [0, 1, 2].some(c => Math.abs(after[offset + c] - before[offset + c]) > 40);
        if (delta) {
          changed++;
          assert(x >= info.width - layout.width - layout.margin && x < info.width - layout.margin);
          assert(y >= info.height - layout.height - layout.margin && y < info.height - layout.margin);
        }
      }
      assert(changed > 20, `watermark missing on frame ${frame}`);
    }
  }
});

function record(args, name) {
  const child = spawn(cli, ['record', '--then', "printf 'CHILD_OUTPUT\\n'", '--silent', '--crop', 'off', '-o', join(root, name + '.gif'), ...args], {
    env: { ...process.env, NODE_OPTIONS: `--require=${mock}`, S2G_TEST_VIDEO: normal }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', x => { stdout += x; });
  child.stderr.on('data', x => { stderr += x; });
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => resolve({ code, stdout, stderr }));
  });
}

test('--then --json reserves stdout for a single JSON result', async () => {
  const result = await record(['--json'], 'json');
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).commandExit, 0);
  assert(result.stderr.includes('CHILD_OUTPUT'));
});

test('--then -q reserves stdout for the resulting path', async () => {
  const result = await record(['-q'], 'quiet');
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout.trim(), join(root, 'quiet.gif'));
  assert(result.stderr.includes('CHILD_OUTPUT'));
});

test('ready-file never appears during countdown and contains timestamp when published', async () => {
  const ready = join(root, 'ready');
  const recording = record(['--countdown', '1', '--ready-file', ready, '--json'], 'ready');
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.equal(existsSync(ready), false);
  const result = await recording;
  assert.equal(result.code, 0, result.stderr);
  assert(Number(await readFile(ready, 'utf8')) > 0);
});

test('invalid crop fails with a useful diagnostic', () => {
  assert.throws(() => convert(normal, 'invalid', ['--crop', '0,0,999,999']), error => error.status === 1 && error.stderr.includes('超出源画面'));
});
