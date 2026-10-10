import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { rm, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';

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

export function run(bin, args, { quiet = false, label = '', verbose = false, onStderrLine } = {}) {
  if (verbose) process.stderr.write(`  $ ${bin} ${args.map(shellQuote).join(' ')}\n`);
  const progress = Boolean(label) && !quiet && showProgress();
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let pendingLine = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > 8_000_000) stdout = stdout.slice(-4_000_000);
    });
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      if (onStderrLine) {
        const lines = (pendingLine + text).split('\n');
        pendingLine = lines.pop();
        lines.forEach(onStderrLine);
      }
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
      if (onStderrLine && pendingLine) onStderrLine(pendingLine);
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
    '-vf', `tblend=all_mode=difference,format=gray,lutyuv=y='if(lt(val,${opts.gate ?? 16}),0,val)',cropdetect=limit=4:round=2:reset=0:skip=0`,
    '-f', 'null', '-',
  ], { quiet: true, verbose: opts.verbose });
  const hits = [...stderr.matchAll(/crop=(\d+):(\d+):(\d+):(\d+)/g)];
  if (!hits.length) return null;
  const [, w, h, x, y] = hits[hits.length - 1].map(Number);
  return { x, y, w, h };
}

export function normalizeCrop(crop, srcW, srcH, pad) {
  if (!crop) return null;
  if (srcW < 2 || srcH < 2) return null;
  const floorEven = (n) => Math.floor(n / 2) * 2;
  const ceilEven = (n) => Math.ceil(n / 2) * 2;
  const x = Math.max(0, Math.min(floorEven(crop.x - pad), floorEven(srcW - 2)));
  const y = Math.max(0, Math.min(floorEven(crop.y - pad), floorEven(srcH - 2)));
  const right = Math.min(floorEven(srcW), ceilEven(crop.x + crop.w + pad));
  const bottom = Math.min(floorEven(srcH), ceilEven(crop.y + crop.h + pad));
  const result = { x, y, w: Math.max(2, right - x), h: Math.max(2, bottom - y) };
  // Cropping away a few pixels buys nothing but resampling cost.
  if (result.w * result.h >= srcW * srcH * 0.97) return null;
  return result;
}

export async function extractKeyframes({
  input, outDir, pattern, crop, width, sensitivity, quiet, label, verbose,
}) {
  const chain = [];
  if (crop) chain.push(`crop=${crop.w}:${crop.h}:${crop.x}:${crop.y}`);
  if (width) chain.push(`scale=${width}:-2:flags=lanczos`);
  chain.push(`mpdecimate=${SENSITIVITY[sensitivity] ?? SENSITIVITY.default}`);
  // Do not discard a changed frame here: mpdecimate will discard its static
  // successors too. Rate limiting happens after extraction, preserving the end.
  chain.push('showinfo');

  const times = [];
  await run(ffmpeg, [
    '-hide_banner', '-loglevel', 'info', '-y', '-i', input,
    '-vf', chain.join(','),
    '-fps_mode', 'vfr', '-start_number', '1', join(outDir, pattern),
  ], { quiet, label, verbose, onStderrLine: (line) => {
    const match = line.match(/pts_time:([-+0-9.eE]+)/);
    if (match) times.push(Number(match[1]));
  } });
  return times;
}

// Keep the first and final state even when the last change is very quick.
// The display delays enforce the requested playback frame-rate limit.
export function applyFrameRate(times, minInterval) {
  if (!times.length) return [];
  const kept = [0];
  for (let i = 1; i < times.length - 1; i++) {
    if (times[i] - times[kept.at(-1)] >= minInterval - 1e-6) kept.push(i);
  }
  const last = times.length - 1;
  if (last > 0) {
    while (kept.length > 1 && times[last] - times[kept.at(-1)] < minInterval - 1e-6) kept.pop();
    kept.push(last);
  }
  return kept;
}

export function applyFrameCap(times, cap) {
  if (!cap || times.length <= cap) return times.map((_, i) => i);
  if (cap === 1) return [times.length - 1];
  return Array.from({ length: cap }, (_, i) => Math.round(i * (times.length - 1) / (cap - 1)));
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
    lines.push(`file '${f.replace(/'/g, "'\\''")}'`, 'option framerate 100', `duration ${(delays[i] / 100).toFixed(2)}`);
  });
  // The concat demuxer ignores the last entry's duration, so the final frame is
  // listed twice to make it hold on screen.
  lines.push(`file '${frames[frames.length - 1].replace(/'/g, "'\\''")}'`, 'option framerate 100');
  await writeFile(file, lines.join('\n') + '\n', 'utf8');
}

export function watermarkLayout(imageSize, frameSize) {
  // The native renderer supplies 2x type. Cap its footprint after crop + resize,
  // so it always fits even a very small or unusually narrow recording.
  const margin = Math.max(0, Math.floor(Math.min(12, frameSize.width * 0.02, frameSize.height * 0.04)));
  const scale = Math.min(0.5, frameSize.width * 0.35 / imageSize.width,
    frameSize.height * 0.2 / imageSize.height);
  return { width: Math.max(1, Math.floor(imageSize.width * scale)),
    height: Math.max(1, Math.floor(imageSize.height * scale)), margin };
}

export async function encodeGif({ listFile, out, palette, watermark, quiet, label, verbose }) {
  const inArgs = ['-f', 'concat', '-safe', '0', '-i', listFile];
  const common = { quiet, label, verbose };
  let composite = '';
  let video = '[0:v]';
  if (watermark) {
    const { width, height, margin } = watermarkLayout(watermark.imageSize, watermark.frameSize);
    inArgs.push('-i', watermark.path);
    composite = `[1:v]scale=${width}:${height}:flags=lanczos[mark];`
      + `[0:v][mark]overlay=x=main_w-overlay_w-${margin}:y=main_h-overlay_h-${margin}:format=rgb:eof_action=repeat[marked]`;
    video = '[marked]';
  }
  if (!palette) {
    await run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...inArgs,
      ...(watermark ? ['-filter_complex', composite, '-map', video] : []),
      '-fps_mode', 'vfr', '-loop', '0', '-f', 'gif', out], common);
    return;
  }
  // 调色板是中间产物，编码结束（无论成败）就删掉，不留在输出目录
  const palFile = join(dirname(listFile), 'palette.png');
  try {
    await run(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y', ...inArgs,
      ...(watermark ? ['-filter_complex', `${composite};${video}palettegen=stats_mode=full`]
        : ['-vf', 'palettegen=stats_mode=full']), palFile,
    ], common);
    await run(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y', ...inArgs, '-i', palFile,
      '-filter_complex', `${watermark ? composite + ';' : ''}${video}[${watermark ? 2 : 1}:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`,
      '-fps_mode', 'vfr', '-loop', '0', '-f', 'gif', out,
    ], common);
  } finally {
    await rm(palFile, { force: true });
  }
}
