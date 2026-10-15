const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { spawn } = require('child_process');

(async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'saphir-live-benchmark-test-'));
  const logs = path.join(root, 'logs'); fs.mkdirSync(logs);
  const stdout = path.join(logs, 'app.stdout.log'); fs.writeFileSync(stdout, 'private warning not for export\n');
  const calls = []; let archive;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', data => { body += data; });
    req.on('end', () => {
      const id = crypto.randomBytes(16).toString('hex');
      calls.push([req.method, req.url]);
      if (req.url === '/auth/login') {
        assert.equal(req.method, 'POST'); assert.equal(JSON.parse(body).password, 'benchmark-secret');
      } else { assert.equal(req.headers.authorization, 'Bearer private-test-token'); }
      const status = req.url === '/review/bootstrap' ? 403 : req.url === '/dashboard/bootstrap' ? 500 : 200;
      fs.appendFileSync(stdout, 'SAPHIR_PERF ' + JSON.stringify({ id, name: req.method + ' ' + req.url, totalMs: 12, status, operations: { 'cache.readmodel.hit': 1 }, functions: {} }) + '\n');
      res.writeHead(status, { 'Content-Type': 'application/json', 'X-SAPHIR-Trace': id });
      res.end(JSON.stringify(req.url === '/auth/login' ? { token: 'private-test-token' } : { employeeName: 'Private Person', salary: 123456 }));
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const script = path.resolve(__dirname, '../../scripts/benchmark-live-app.ps1').replace(/'/g, "''");
    const command = `$credential = New-Object PSCredential('test-user', (ConvertTo-SecureString 'benchmark-secret' -AsPlainText -Force)); & '${script}' -Credential $credential -SkipLaunch -BaseUrl 'http://127.0.0.1:${server.address().port}/'`;
    const output = await new Promise((resolve, reject) => {
      const child = spawn(process.env.SAPHIR_POWERSHELL || 'pwsh', ['-NoProfile', '-Command', command], { env: { ...process.env, SAPHIR_RUNTIME_ROOT: root } });
      let text = ''; child.stdout.on('data', x => { text += x; }); child.stderr.on('data', x => { text += x; });
      child.on('error', reject); child.on('close', code => code === 0 ? resolve(text) : reject(new Error(text)));
    });
    archive = output.match(/Finished\. Send this file: (.+\.zip)/)[1].trim();
    const folder = archive.slice(0, -4);
    assert.match(path.basename(folder), /^benchmark-\d{8}T\d{6}-[0-9a-f]{32}$/);
    const rows = JSON.parse(fs.readFileSync(path.join(folder, 'requests.json'), 'utf8').replace(/^\uFEFF/, ''));
    assert.equal(rows.length, 16); // login + seven GETs twice + own session logout
    assert.equal(rows.filter(x => x.status === 403).length, 2);
    assert.equal(rows.filter(x => x.status === 500).length, 2);
    assert.equal(calls.filter(x => x[0] !== 'GET' && !['/auth/login', '/auth/logout'].includes(x[1])).length, 0);
    assert.equal(calls.filter(x => x[1] === '/employees/bootstrap?scope=all').length, 2);
    const summaries = fs.readFileSync(path.join(folder, 'backend-summary.jsonl'), 'utf8').trim().split(/\r?\n/);
    assert.equal(summaries.length, rows.length);
    for (const file of fs.readdirSync(folder)) {
      assert(!/benchmark-secret|private-test-token|Private Person|123456|test-user|private warning/.test(fs.readFileSync(path.join(folder, file), 'utf8')), 'Sensitive content exported');
    }
    assert(fs.statSync(archive).size > 0);
    console.log('Live benchmark: automatic read-only GETs, error statuses, correlated summaries, ZIP and privacy passed.');
  } finally {
    server.close();
    if (archive && /^benchmark-\d{8}T\d{6}-[0-9a-f]{32}\.zip$/.test(path.basename(archive))) {
      fs.rmSync(archive, { force: true }); fs.rmSync(archive.slice(0, -4), { recursive: true, force: true });
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
