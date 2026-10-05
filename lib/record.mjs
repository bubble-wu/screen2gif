import { spawn, execFile } from 'node:child_process';
import { stat, rm } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { probe } from './video.mjs';

const APPLESCRIPT_FRONT_WINDOW = `
tell application "System Events"
  set frontProc to first process whose frontmost is true
  set win to window 1 of frontProc
  set {px, py} to position of win
  set {pw, ph} to size of win
  return (px as text) & "," & (py as text) & "," & (pw as text) & "," & (ph as text)
end tell`;

export function frontWindowRegion() {
  return new Promise((resolve, reject) => {
    execFile('osascript', ['-e', APPLESCRIPT_FRONT_WINDOW], { timeout: 10_000 }, (err, stdout) => {
      if (err) {
        return reject(new Error(
          `取不到前台窗口位置（${err.stderr?.trim().split('\n').pop() || err.message.split('\n')[0]}）。` +
          `有些应用不向 System Events 暴露窗口，可改用 --region x,y,w,h（屏幕点）`
        ));
      }
      const parts = stdout.trim().split(',').map((n) => Number(n.trim()));
      if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) {
        return reject(new Error(`窗口位置解析失败: ${stdout.trim()}`));
      }
      const [x, y, w, h] = parts.map(Math.round);
      if (w < 8 || h < 8) return reject(new Error(`前台窗口太小: ${w}x${h}`));
      resolve({ x, y, w, h });
    });
  });
}

function waitForExit(child) {
  return new Promise((resolve) => {
    child.on('exit', (code, signal) => resolve({ code, signal }));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function beep(name) {
  const child = spawn('afplay', [`/System/Library/Sounds/${name}.aiff`], {
    stdio: 'ignore', detached: true,
  });
  child.unref();
}

// screencapture finalizes the .mov only when it receives SIGINT, so a manual
// stop sends the signal and waits for the process to flush the moov atom.
// A SIGKILLed screencapture leaks its capture session and wedges every later
// recording, so stopping always escalates politely and never hard-kills.
export async function record({
  out, duration, clicks, display, region, interactive,
  countdown = 3, silent = false, quiet = false, onEvent,
}) {
  const cue = (name) => { if (!silent && !quiet) beep(name); };
  const say = (m) => { if (!quiet) process.stderr.write(`${m}\n`); };

  // -J video shows macOS' own recording toolbar and starts capturing at once,
  // so the menu-bar stop button works from any app. -R still applies.
  const args = interactive
    ? ['-J', 'video', '-x']
    : ['-v', '-x'];
  if (clicks) args.push('-k');
  if (display) args.push('-D', String(display));
  // -V must precede -R: with -R first, screencapture ignores both the timer
  // and SIGINT and never finalizes the file.
  if (duration && !interactive) args.push('-V', String(duration));
  if (region) args.push('-R', `${region.x},${region.y},${region.w},${region.h}`);
  args.push(out);

  let rl = null;
  const waitLine = async (prompt) => {
    if (!process.stdin.isTTY) return false;
    if (!rl) rl = createInterface({ input: process.stdin, output: process.stderr });
    if (prompt) say(prompt);
    await new Promise((resolve) => rl.once('line', resolve));
    return true;
  };

  const manual = !duration && !interactive;
  if (manual && !process.stdin.isTTY) {
    throw new Error('非交互终端请用 -d <秒> 定时录制，或 --interactive 用屏幕上的原生按钮控制');
  }
  if (manual) await waitLine('  ▶ 准备好后按 Enter 开始录制');

  for (let i = countdown; i > 0; i--) {
    say(`  ${i}…`);
    cue('Tink');
    await sleep(1000);
  }

  onEvent?.(`screencapture ${args.join(' ')}`);
  const child = spawn('/usr/sbin/screencapture', args, { stdio: 'ignore' });
  const exited = waitForExit(child);
  cue('Glass');

  let stopping = false;
  let timers = [];
  const stop = () => {
    if (stopping) return;
    stopping = true;
    const later = (ms, fn) => timers.push(setTimeout(fn, ms));
    try { child.kill('SIGINT'); } catch { /* already gone */ }
    later(3000, () => { try { child.kill('SIGTERM'); } catch { /* gone */ } });
    later(5000, () => { try { child.kill('SIGKILL'); } catch { /* gone */ } });
  };
  const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };

  // -V normally exits on its own; the watchdog covers a wedged capture session.
  const watchdog = duration ? setTimeout(stop, (duration + 6) * 1000) : null;
  process.once('SIGINT', stop);

  if (!duration) {
    say(interactive
      ? '  ● 录制中… 点菜单栏的停止按钮结束，或回终端按 Enter / Ctrl-C'
      : '  ● 录制中… 按 Enter 停止 (Ctrl-C 同样停止并继续转码)');
    if (process.stdin.isTTY) {
      // In interactive mode the native stop button ends the process on its
      // own; the Enter listener just races it.
      const linePromise = waitLine(null).then(() => stop());
      const done = await Promise.race([exited.then(() => 'exit'), linePromise.then(() => 'line')]);
      if (done === 'line') await exited;
    } else {
      await exited;
    }
  } else if (!quiet) {
    process.stderr.write(`  ● 录制中… ${duration}s\n`);
  }

  const { code, signal } = await exited;
  clearTimers();
  clearTimeout(watchdog);
  process.removeListener('SIGINT', stop);
  rl?.close();
  cue('Tink');

  let size = 0;
  try { size = (await stat(out)).size; } catch { /* missing */ }
  if (size < 4096) {
    const how = signal === 'SIGKILL' ? '录制进程被强杀，文件未写完。' : '';
    throw new Error(
      `录屏文件异常 (${size} 字节)。${how}` +
      `常见原因：缺少「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制，` +
      `勾选运行本命令的终端 / Qoder），或上一次录制被强杀导致录屏会话卡死` +
      `（重启 ControlCenter 或注销可恢复）。`
    );
  }
  return { path: out, bytes: size, exitCode: code };
}

export async function checkPermission() {
  const probePath = `/tmp/s2g-perm-${process.pid}.mov`;
  try {
    await record({ out: probePath, duration: 1, countdown: 0, silent: true, quiet: true });
    const { width, height } = await probe(probePath);
    return { ok: true, width, height };
  } catch (err) {
    return { ok: false, error: err.message.split('\n')[0] };
  } finally {
    await rm(probePath, { force: true });
  }
}
