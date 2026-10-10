import { spawn, execFile } from 'node:child_process';
import { stat, rm, writeFile, mkdtemp } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { probe } from './video.mjs';
import { responsibleAppName, openScreenCaptureSettings } from './deps.mjs';

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
    child.on('error', () => resolve({ code: 1, signal: null }));
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
// 外控三钩子（--then / --ready-file 的底层，供 agent 编排）：
//   onStarted：screencapture 进程拉起那一刻（倒计时已结束）同步回调，
//              距实际出画约百毫秒
//   until：    该 promise 完成即停止录制（结果不论成败都收尾转码）
//   readyFile：screencapture 拉起那一刻创建该文件（先清掉旧文件），外部脚本/agent 轮询它
// A SIGKILLed screencapture leaks its capture session and wedges every later
// recording; the stop ladder below still escalates to SIGKILL as a last
// resort so a wedged stop can't hang the CLI forever — at the cost that the
// SIGKILL step may itself wedge the session (recover: killall ControlCenter).
export async function record({
  out, duration, clicks, display, region, interactive,
  countdown = 3, silent = false, quiet = false, onEvent,
  onStarted, until, readyFile,
}) {
  const cue = (name) => { if (!silent && !quiet) beep(name); };
  const say = (m) => { if (!quiet) process.stderr.write(`${m}\n`); };

  if (readyFile) {
    // Test a separate name: the actual signal must never appear during preflight.
    let probeDir;
    try {
      probeDir = await mkdtemp(join(dirname(readyFile), '.s2g-ready-'));
      await writeFile(join(probeDir, 'probe'), '');
      await rm(readyFile, { force: true });
    } catch (e) {
      throw new Error(`--ready-file 无法写入 ${readyFile}：${e.message}`);
    } finally {
      if (probeDir) await rm(probeDir, { recursive: true, force: true });
    }
  }

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

  // until 是第四种模式：开始后由外部信号（--then 的命令退出）决定何时停止，
  // 既不需要 TTY 也不需要预估时长，专给非交互的 agent 编排用
  const manual = !duration && !interactive && !until;
  if (manual && !process.stdin.isTTY) {
    throw new Error('非交互终端请用 -d <秒> 定时录制、--interactive 用屏幕上的原生按钮，或 --then \'<命令>\' 录制期间执行命令');
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
  const captureStartedAt = Date.now();
  cue('Glass');
  // 就绪信号：文件内容是开录时间戳（毫秒），可供外部测量等待耗时
  if (readyFile) {
    try { await writeFile(readyFile, `${Date.now()}\n`); }
    catch (e) { say(`  ⚠ 无法写入 ready-file：${e.message}`); }
  }
  onStarted?.();

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

  if (until) {
    say('  ● 录制中… 停止信号由调用方控制（Ctrl-C 可提前结束并照常转码）');
    // until 拒绝（命令起不来等）也必须走 stop 收尾，否则 screencapture 泄漏
    let viaSignal = false;
    try {
      await Promise.race([exited, until.then(() => { viaSignal = true; })]);
    } finally {
      // 命令秒退的竞态：screencapture 可能还没初始化完，立刻 SIGINT 会得到
      // 0 字节文件（还容易被误报成缺权限）。保底录满 1 秒再停。
      if (viaSignal) {
        const left = 1000 - (Date.now() - captureStartedAt);
        if (left > 0) await sleep(left);
      }
      stop();
    }
    await exited;
  } else if (!duration) {
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

  let size = 0;
  try { size = (await stat(out)).size; } catch { /* missing */ }
  // 结束音放在文件校验之后：录坏了也响「结束音」会误导用户以为成功
  if (size >= 4096) cue('Tink');
  if (size < 4096) {
    if (signal === 'SIGKILL') {
      throw new Error(
        '录制进程被强杀，文件未写完。若反复出现：killall ControlCenter 或注销可恢复'
      );
    }
    // 到这里基本就是「屏幕录制」权限没给。权限授给的是运行命令的终端 app，
    // 查出它的名字直接告诉用户勾选谁，并把系统设置面板替用户打开（交互终端）。
    const app = responsibleAppName();
    const opened = openScreenCaptureSettings();
    throw new Error(
      `录屏文件异常 (${size} 字节)：缺少「屏幕录制」权限。\n` +
      (opened ? '已打开系统设置 → 隐私与安全性 → 屏幕录制，'
              : '请打开 系统设置 → 隐私与安全性 → 屏幕录制，') +
      `勾选「${app ?? '运行本命令的终端应用'}」后重新运行本命令。\n` +
      `（若该项已勾选仍失败：上次录制被强杀导致会话卡死，killall ControlCenter 或注销可恢复）`
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
