import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const CANDIDATES = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];

function resolveBin(name) {
  const fromEnv = process.env[`S2G_${name.toUpperCase()}`];
  if (fromEnv) return fromEnv;
  for (const dir of CANDIDATES) {
    const p = join(dir, name);
    if (existsSync(p)) return p;
  }
  return name;
}

export const ffmpeg = resolveBin('ffmpeg');
export const ffprobe = resolveBin('ffprobe');

const shellQuote = (s) => (/^[A-Za-z0-9_./:@=-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`);
const showProgress = () => process.stderr.isTTY === true;

export function run(bin, args, { quiet = false, label = '', verbose = false } = {}) {
  if (verbose) process.stderr.write(`  $ ${bin} ${args.map(shellQuote).join(' ')}\n`);
  const progress = Boolean(label) && !quiet && showProgress();
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > 8_000_000) stdout = stdout.slice(-4_000_000);
    });
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      stderr += text;
      if (stderr.length > 8_000_000) stderr = stderr.slice(-4_000_000);
      if (progress) {
        const tail = text.split('\r').filter(Boolean).pop()?.trim();
        if (tail?.startsWith('frame=') || tail?.startsWith('size=')) {
          process.stderr.write(`\r  ${label} ${tail.slice(0, 84).padEnd(84)}`);
        }
      }
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (progress) process.stderr.write(`\r${' '.repeat(100)}\r`);
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`${bin} 退出码 ${code}\n  ${args.map(shellQuote).join(' ')}\n${(stderr || stdout).split('\n').filter(l => !/^(frame=|size=)/.test(l.trim())).slice(-20).join('\n')}`));
    });
  });
}

export async function probe(file) {
  const { stdout } = await run(ffprobe, [
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height,r_frame_rate,nb_frames,duration',
    '-show_entries', 'format=duration',
    '-of', 'json', file,
  ]);
  const info = JSON.parse(stdout);
  const s = info.streams?.[0];
  if (!s) throw new Error(`${file} 里没有视频流`);
  const [num, den] = String(s.r_frame_rate || '0/1').split('/').map(Number);
  return {
    width: s.width,
    height: s.height,
    fps: den ? num / den : 0,
    nbFrames: Number(s.nb_frames) || 0,
    duration: Number(s.duration ?? info.format?.duration ?? 0),
  };
}

// mpdecimate rungs. Screen recordings carry compression noise on every frame,
// so ffmpeg's film-oriented defaults are the *least* sensitive rung here and
// anything looser than "high" keeps every frame of a 4K capture.
export const SENSITIVITY = {
  low: 'hi=768:lo=320:frac=0.33',
  default: 'hi=512:lo=224:frac=0.22',
  high: 'hi=256:lo=112:frac=0.10',
};

// tblend measured directly on a screencapture .mov reports a constant bogus
// offset even across identical frames, so the motion bounding box is measured
// on the decoded PNG keyframes instead, where the diff is trustworthy.
export async function detectCrop(pngDir, pattern, opts = {}) {
  const { stderr } = await run(ffmpeg, [
    '-hide_banner', '-nostats', '-framerate', '10', '-i', join(pngDir, pattern),
    '-vf', `tblend=all_mode=difference,format=gray,lutyuv=y='if(lt(val,${opts.gate ?? 16}),0,val)',cropdetect=limit=4:round=2:reset=0`,
    '-f', 'null', '-',
  ], { quiet: true, verbose: opts.verbose });
  const hits = [...stderr.matchAll(/crop=(\d+):(\d+):(\d+):(\d+)/g)];
  if (!hits.length) return null;
  const [, w, h, x, y] = hits[hits.length - 1].map(Number);
  return { x, y, w, h };
}

export function normalizeCrop(crop, srcW, srcH, pad) {
  if (!crop) return null;
  const even = (n) => Math.max(2, Math.round(n / 2) * 2);
  const x = Math.max(0, Math.min(crop.x - pad, srcW - 2));
  const y = Math.max(0, Math.min(crop.y - pad, srcH - 2));
  const w = Math.min(crop.w + pad * 2, srcW - x);
  const h = Math.min(crop.h + pad * 2, srcH - y);
  const result = { x: even(x), y: even(y), w: even(w), h: even(h) };
  // Cropping away a few pixels buys nothing but resampling cost.
  if (result.w * result.h >= srcW * srcH * 0.97) return null;
  return result;
}

export async function extractKeyframes({
  input, outDir, pattern, crop, width, sensitivity, minInterval, quiet, label, verbose,
}) {
  const chain = [];
  if (crop) chain.push(`crop=${crop.w}:${crop.h}:${crop.x}:${crop.y}`);
  if (width) chain.push(`scale=${width}:-2:flags=lanczos`);
  chain.push(`mpdecimate=${SENSITIVITY[sensitivity] ?? SENSITIVITY.default}`);
  chain.push(`select='isnan(prev_selected_t)+gte(t-prev_selected_t,${minInterval})'`);
  chain.push('showinfo');

  const { stderr } = await run(ffmpeg, [
    '-hide_banner', '-loglevel', 'info', '-y', '-i', input,
    '-vf', chain.join(','),
    '-fps_mode', 'vfr', '-start_number', '1', join(outDir, pattern),
  ], { quiet, label, verbose });

  return [...stderr.matchAll(/pts_time:([0-9.]+)/g)].map((m) => Number(m[1]));
}

// Frames beyond the cap are dropped evenly so long recordings stay bounded.
export function applyFrameCap(times, cap) {
  if (!cap || times.length <= cap) return times.map((_, i) => i);
  const step = times.length / cap;
  const kept = new Set();
  for (let i = 0; i < cap; i++) kept.add(Math.min(times.length - 1, Math.floor(i * step)));
  return [...kept].sort((a, b) => a - b);
}

// GIF delays are integer centiseconds; browsers clamp anything under ~2cs, so
// the floor keeps fast passages from collapsing into a frozen frame.
export function computeDelays(times, { minGap, maxGap, endHold }) {
  const cs = (s) => Math.max(2, Math.round(Math.min(Math.max(s, minGap), maxGap) * 100));
  return times.map((t, i) => (i === times.length - 1 ? cs(endHold) : cs(times[i + 1] - t)));
}

export async function buildConcatList(frames, delays, file) {
  const lines = ['ffconcat version 1.0'];
  frames.forEach((f, i) => {
    lines.push(`file '${f}'`, `duration ${(delays[i] / 100).toFixed(2)}`);
  });
  // The concat demuxer ignores the last entry's duration, so the final frame is
  // listed twice to make it hold on screen.
  lines.push(`file '${frames[frames.length - 1]}'`);
  await writeFile(file, lines.join('\n') + '\n', 'utf8');
}

export async function encodeGif({ listFile, out, palette, quiet, label, verbose }) {
  const inArgs = ['-f', 'concat', '-safe', '0', '-i', listFile];
  const common = { quiet, label, verbose };
  if (!palette) {
    await run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...inArgs, '-loop', '0', out], common);
    return;
  }
  // 调色板是中间产物，编码结束（无论成败）就删掉，不留在输出目录
  const palFile = `${out}.palette.png`;
  try {
    await run(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y', ...inArgs,
      '-vf', 'palettegen=stats_mode=full', palFile,
    ], common);
    await run(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y', ...inArgs, '-i', palFile,
      '-filter_complex', '[0:v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle',
      '-loop', '0', out,
    ], common);
  } finally {
    await rm(palFile, { force: true });
  }
}
