#!/usr/bin/env node
// Print the latest proven future five-hour reset from explicitly scoped Claude
// transcripts. Never infer limits from prose, scan a log tree, or read credentials.
import fs from 'node:fs';
import path from 'node:path';

const [config, primary = '', engine = '', root = '', state = '', key = ''] = process.argv.slice(2);
const now = Math.floor(Date.now() / 1000);
const maxBytes = 1024 * 1024;
const files = new Set();
function add(file) {
  if (typeof file === 'string' && path.isAbsolute(file) && files.size < 32) files.add(file);
}
function tail(file, bytes = maxBytes) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return '';
    const start = Math.max(0, stat.size - bytes);
    const buf = Buffer.alloc(Math.min(bytes, stat.size));
    const count = fs.readSync(fd, buf, 0, buf.length, start);
    const text = buf.subarray(0, count).toString('utf8');
    return start ? text.slice(text.indexOf('\n') + 1) : text;
  } catch { return ''; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
if (!config || !fs.existsSync(path.join(config, 'claude-quota-pause'))) process.exit(0);
add(primary);
// Claude records --session-id under its cwd project directory. Only the
// conversation this host explicitly launched is eligible; no directory scan.
if (/^[a-zA-Z0-9-]+$/.test(engine) && path.isAbsolute(root)) {
  let physical = root;
  try { physical = fs.realpathSync(root); } catch { /* retain explicit cwd */ }
  add(path.join(process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME || '', '.claude'),
    'projects', physical.replace(/[^a-zA-Z0-9]/g, '-'), `${engine}.jsonl`));
}
for (const file of tail(path.join(config, 'claude-quota-transcripts'), 16384).split('\n')) add(file.trim());
const validReset = value => Number.isSafeInteger(value) && value > now && value <= now + 5 * 3600 + 300;
const cacheFile = state && key ? path.join(state, '.claude-quota-reset') : '';
let reset = 0;
try {
  const cached = JSON.parse(tail(cacheFile, 4096));
  if (cached.key === key && validReset(cached.reset)) reset = cached.reset;
} catch { /* absent, expired, or foreign-session evidence is inert */ }
const priorReset = reset;
for (const file of files) {
  for (const line of tail(file).split('\n')) {
    let row;
    try { row = JSON.parse(line); } catch { continue; }
    if (row?.isApiErrorMessage !== true || row.apiError !== 'usage_limit_reached') continue;
    for (const limit of [row.quotaLimits, row.apiErrorParams?.rate_limit_info]) {
      if (limit?.status !== 'rejected' || limit.rateLimitType !== 'five_hour') continue;
      if (validReset(limit.resetsAt)) reset = Math.max(reset, limit.resetsAt);
    }
  }
}
if (cacheFile && reset > priorReset) {
  const temporary = `${cacheFile}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, JSON.stringify({key, reset}) + '\n', {mode: 0o600, flag: 'wx'});
    fs.renameSync(temporary, cacheFile);
  } catch { /* observed evidence can still pause this process */ }
  finally { try { fs.unlinkSync(temporary); } catch { /* renamed or absent */ } }
}
if (reset) process.stdout.write(`${reset}\n`);
