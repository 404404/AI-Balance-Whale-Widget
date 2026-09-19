'use strict';

// Keep the mature Windows Codex-following host intact. macOS launches the
// standalone host below, so the two lifecycles cannot accidentally share host
// heartbeat, Windows handles, or coordinate conversions.
if (process.platform === 'darwin' || process.argv.includes('--standalone') || process.env.WHALE_DESKTOP_MODE === 'standalone') {
  require('./standalone-main.cjs');
} else {
  require('./follow-main.cjs');
}
