// Preloaded only by integration tests; never records the user's screen.
const cp = require('node:child_process');
const { syncBuiltinESMExports } = require('node:module');
const realSpawn = cp.spawn;
cp.spawn = function (bin, args, options) {
  if (bin !== '/usr/sbin/screencapture') return realSpawn(bin, args, options);
  const script = `
    require('fs').copyFileSync(process.argv[1], process.argv[2]);
    process.on('SIGINT', () => process.exit(0));
    setInterval(() => {}, 1000);
  `;
  return realSpawn(process.execPath, ['-e', script, process.env.S2G_TEST_VIDEO, args.at(-1)], options);
};
syncBuiltinESMExports();
