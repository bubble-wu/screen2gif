import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { ffmpeg, ffprobe } from './video.mjs';

// 依赖自检与一键安装。设计目标：新用户 clone 下来第一条命令就能被领着走完
// 「缺什么 → 装什么 → 缺权限 → 打开设置面板」的完整链路，而不是读 README。

function binWorks(bin) {
  const r = spawnSync(bin, ['-version'], { stdio: 'ignore', timeout: 10_000 });
  return r.status === 0;
}

export function findBrew() {
  for (const p of ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']) {
    if (existsSync(p)) return p;
  }
  return null;
}

/// record/convert 前调用：缺 ffmpeg/ffprobe 时，交互终端里询问是否用
/// Homebrew 安装（stdio: inherit，brew 的进度直接透传）；非交互环境
/// （agent/CI）没有确认手段，直接失败并给出手动安装命令。
export async function ensureFfmpeg() {
  const missing = [];
  if (!binWorks(ffmpeg)) missing.push('ffmpeg');
  if (!binWorks(ffprobe)) missing.push('ffprobe');
  if (!missing.length) return;

  const brew = findBrew();
  if (!process.stdin.isTTY || !brew) {
    throw new Error(
      `缺少 ${missing.join(' / ')}。安装：brew install ffmpeg` +
      (brew ? '' : '（本机还没有 Homebrew，先到 https://brew.sh 安装）')
    );
  }

  process.stderr.write(`\n✗ 缺少 ${missing.join(' / ')}\n`);
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const answer = await new Promise((res) => {
    rl.question('现在通过 Homebrew 安装？[Y/n] ', (a) => res(a.trim().toLowerCase()));
    // Ctrl-D（EOF）静默退出会让人摸不着头脑，按默认 Y 走
    rl.once('close', () => res(''));
  });
  rl.close();
  if (answer === 'n' || answer === 'no') {
    throw new Error('已取消安装。手动安装：brew install ffmpeg');
  }

  process.stderr.write('  brew install ffmpeg …（首次可能需要几分钟）\n');
  const r = spawnSync(brew, ['install', 'ffmpeg'], { stdio: 'inherit' });
  if (r.status !== 0) {
    throw new Error(`brew install ffmpeg 失败（exit ${r.status ?? '信号中断'}），可手动重试`);
  }
  const still = missing.filter((m) => !binWorks(m === 'ffmpeg' ? ffmpeg : ffprobe));
  if (still.length) {
    throw new Error(`安装完成但仍然找不到 ${still.join(' / ')}，请检查 PATH 里有没有 Homebrew 的 bin 目录`);
  }
  process.stderr.write('  ✓ 依赖已就绪，继续执行…\n');
}

let cachedApp = undefined;

/// macOS 的「屏幕录制」权限不是授给 screen2gif，而是授给发起 screencapture 的
/// 责任进程——通常就是运行命令的终端 app。沿父进程链向上找第一个 .app，
/// 把名字告诉用户，比「勾选运行本命令的终端 / Qoder」的静态文案准确得多。
export function responsibleAppName() {
  if (cachedApp !== undefined) return cachedApp;
  cachedApp = null;
  try {
    let pid = process.pid;
    for (let i = 0; i < 24 && pid > 1; i++) {
      const out = execFileSync('ps', ['-o', 'ppid=,comm=', '-p', String(pid)], { encoding: 'utf8' }).trim();
      const m = out.match(/^(\d+)\s+(.*)$/);
      if (!m) break;
      const app = m[2].match(/\/([^/]+)\.app\/Contents\/MacOS\//);
      if (app) { cachedApp = app[1]; break; }
      pid = Number(m[1]);
    }
  } catch { /* ps 不可用（极端环境）→ 返回 null，调用方用通用文案 */ }
  return cachedApp;
}

/// 直接打开系统设置的「屏幕录制」面板。只在交互终端里弹——
/// agent/CI 里乱抢焦点开设置窗口只会吓到人。
export function openScreenCaptureSettings() {
  if (!process.stdin.isTTY) return false;
  try {
    const child = spawn('open', [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    ], { stdio: 'ignore', detached: true });
    child.unref();
    return true;
  } catch { return false; }
}

export { binWorks };
