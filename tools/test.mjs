import { spawn, spawnSync } from 'node:child_process';
import {
    mkdirSync, mkdtempSync, readFileSync, readdirSync, existsSync, writeFileSync, statSync,
} from 'node:fs';
import { createConnection, createServer } from 'node:net';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

const [mode, binaryArg, optimize = 'debug'] = process.argv.slice(2);
const binary = resolve(binaryArg);
const root = resolve('.');
const commit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
assert.equal(commit.status, 0, commit.stderr);
mkdirSync(join(root, '.zig-cache'), { recursive: true });
const work = mkdtempSync(join(process.env.ZIG_LOCAL_CACHE_DIR ?? join(root, '.zig-cache'), 'e2e-'));

function run(command, args, cwd = root, timeout) {
    const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `${command} ${args.join(' ')}\n${result.stdout}\n${result.stderr}`);
    return result.stdout + result.stderr;
}

function example(name) {
    const dir = join(root, 'examples', name);
    run('zig', ['build', '-j4'], dir);
    const wasm = join(dir, 'zig-out', 'bin', `${name}.wasm`);
    assert.ok(WebAssembly.validate(readFileSync(wasm)), `${name}: invalid wasm`);
    const output = join(work, name);
    run(binary, ['build', '--wasm', wasm, '--output-dir', output, '--force']);
    assert.ok(existsSync(join(output, 'index.html')), `${name}: missing index.html`);
    const js = readdirSync(output).find((f) => f.endsWith('.js'));
    assert.ok(js, `${name}: missing JS`);
    run(process.execPath, ['--check', join(output, js)]);
    return wasm;
}

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

async function bounded(promise, timeoutMs, description) {
    let timer;
    try {
        return await Promise.race([promise, new Promise((_, fail) => {
            timer = setTimeout(() => fail(new Error(`Timed out: ${description}`)), timeoutMs);
        })]);
    } finally {
        clearTimeout(timer);
    }
}

async function freePort() {
    const probe = createServer();
    await new Promise((ok, fail) => probe.once('error', fail).listen(0, '127.0.0.1', ok));
    const port = probe.address().port;
    await new Promise((ok, fail) => probe.close((err) => err ? fail(err) : ok()));
    return port;
}

function socketEvent(socket, event) {
    return new Promise((ok, fail) => {
        socket.addEventListener(event, ok, { once: true });
        socket.addEventListener('error', () => fail(new Error(`WebSocket ${event} failed`)),
            { once: true });
        if (event !== 'close') socket.addEventListener('close', () =>
            fail(new Error(`WebSocket closed before ${event}`)), { once: true });
    });
}

async function stopServer(server, exited, port) {
    if (server.exitCode === null && server.signalCode === null) server.kill('SIGINT');
    try {
        const status = await bounded(exited, 15000, 'dev server exit and closed output pipes');
        if (process.platform !== 'win32') {
            assert.deepEqual(status, { code: 0, signal: null }, 'dev server did not exit cleanly');
        }
    } catch (error) {
        server.kill('SIGKILL');
        await bounded(exited, 5000, 'forced dev server exit');
        throw error;
    }
    assert.throws(() => process.kill(server.pid, 0), { code: 'ESRCH' },
        'dev server process remains alive');
    const probe = createServer();
    await bounded(new Promise((ok, fail) =>
        probe.once('error', fail).listen(port, '127.0.0.1', ok)), 5000, 'server port release');
    await new Promise((ok, fail) => probe.close((err) => err ? fail(err) : ok()));
}

function maskedFrame(opcode, text) {
    const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
    const body = Buffer.from(text);
    assert.ok(body.length < 126, 'test frames are short');
    const masked = Buffer.from(body.map((byte, index) => byte ^ mask[index % 4]));
    return Buffer.concat([Buffer.from([0x80 | opcode, 0x80 | body.length]), mask, masked]);
}

function serverFrames(buffer) {
    const frames = [];
    let offset = 0;
    while (buffer.length - offset >= 2) {
        let length = buffer[offset + 1] & 127;
        let header = 2;
        if (length === 126) {
            if (buffer.length - offset < 4) break;
            length = buffer.readUInt16BE(offset + 2);
            header = 4;
        }
        assert.ok((buffer[offset + 1] & 127) < 127, 'server frames stay below 64 KiB');
        if (buffer.length - offset < header + length) break;
        const text = buffer.subarray(offset + header, offset + header + length).toString();
        frames.push({ opcode: buffer[offset] & 15, text });
        offset += header + length;
    }
    return { frames, rest: buffer.subarray(offset) };
}

// The server reads frames through webzocket's reader from a static buffer with the provider maximum at 0.
async function webSocketTextAndPing(port) {
    const socket = createConnection({ host: '127.0.0.1', port });
    let received = Buffer.alloc(0);
    let closed = false;
    socket.on('data', (chunk) => { received = Buffer.concat([received, chunk]); });
    socket.on('close', () => { closed = true; });
    socket.on('error', () => { closed = true; });
    const until = async (done, what) => {
        for (let i = 0; i < 200; i++) {
            if (done()) return;
            assert.equal(closed, false, `raw WebSocket closed before ${what}`);
            await sleep(25);
        }
        assert.fail(`raw WebSocket: no ${what}`);
    };
    try {
        await bounded(new Promise((ok, fail) => socket.once('connect', ok).once('error', fail)), 10000, 'raw WebSocket connect');
        socket.write(`GET /__zunk_ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\n` +
            'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
        await until(() => received.includes('\r\n\r\n'), 'handshake reply');
        const end = received.indexOf('\r\n\r\n') + 4;
        const head = received.subarray(0, end).toString();
        assert.match(head, /^HTTP\/1\.1 101 /, 'handshake status');
        assert.match(head, /sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=/i, 'handshake accept key');
        received = received.subarray(end);
        socket.write(maskedFrame(1, 'text frame from the client'));
        for (const text of ['first ping', 'second ping after more traffic']) {
            socket.write(maskedFrame(9, text));
            let pong;
            await until(() => {
                const parsed = serverFrames(received);
                received = parsed.rest;
                pong = parsed.frames.find((frame) => frame.opcode === 10);
                return pong !== undefined;
            }, 'pong');
            assert.equal(pong.text, text, 'pong echoes the ping payload');
        }
        assert.equal(closed, false, 'raw WebSocket stays open after a text frame and two pings');
    } finally {
        socket.destroy();
    }
}

async function devServerCheck(wasm) {
    const started = performance.now();
    const cwd = join(root, 'examples', 'vertex-triangle');
    const source = join(cwd, 'src', 'main.zig');
    const original = readFileSync(source);
    const output = join(cwd, 'dist');
    const port = await freePort();
    const server = spawn(binary, ['run', '--wasm', wasm, '--output-dir', output,
        '--port', String(port)], { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const exited = new Promise((ok, fail) => {
        server.once('error', fail);
        server.once('close', (code, signal) => ok({ code, signal }));
    });
    let log = '';
    let socket;
    let changed = false;
    const ready = new Promise((ok, fail) => {
        const collect = (bytes) => {
            log = (log + bytes).slice(-120000);
            if (log.includes('watch: ready')) ok();
        };
        server.stdout.on('data', collect);
        server.stderr.on('data', collect);
        exited.then(({ code, signal }) =>
            fail(new Error(`server exited before watching: ${code ?? signal}`)), fail);
    });
    try {
        await bounded(ready, 30000, 'dev server listener and initial source observation');
        const url = `http://127.0.0.1:${port}`;
        for (const name of ['index.html', 'app.js', 'vertex-triangle.wasm']) {
            const response = await fetch(`${url}/${name}`, { signal: AbortSignal.timeout(10000) });
            assert.equal(response.status, 200, `${name}: HTTP ${response.status}`);
            let bytes = Buffer.from(await response.arrayBuffer());
            if (name === 'index.html') bytes = Buffer.from(bytes.toString().replace(
                /<script>\s*\(\(\)=>\{const ws=new WebSocket\([\s\S]*?<\/script>/, ''));
            assert.ok(bytes.equals(readFileSync(join(output, name))), `${name}: bytes differ`);
        }
        socket = new WebSocket(`${url.replace('http:', 'ws:')}/__zunk_ws`);
        await bounded(socketEvent(socket, 'open'), 10000, 'reload WebSocket handshake');
        const reload = new Promise((ok, fail) => {
            socket.addEventListener('message', ({ data }) => {
                if (data === 'reload') ok();
                if (String(data).startsWith('error:')) fail(new Error(String(data)));
            });
            socket.addEventListener('error', () => fail(new Error('reload socket failed')));
            socket.addEventListener('close', () => fail(new Error('reload socket closed early')));
        });
        reload.catch(() => {});
        await webSocketTextAndPing(port);
        assert.deepEqual(readFileSync(source), original, 'source changed during server startup');
        changed = true;
        writeFileSync(source, Buffer.concat([original, Buffer.from('\n')]));
        await bounded(reload, 60000, 'successful rebuild and reload after source change');
        assert.match(log, /build: success/, 'reload arrived without a successful build');
    } catch (error) {
        throw new Error(`${error.message}\nDev server output:\n${log}`, { cause: error });
    } finally {
        if (changed) writeFileSync(source, original);
        if (socket) socket.close();
        await stopServer(server, exited, port);
    }
    console.log(`Dev server: page, JS, wasm, WebSocket reload, cleanup ` +
        `(${((performance.now() - started) / 1000).toFixed(3)}s)`);
}

function findBrowser() {
    const candidates = [process.env.CHROME_BIN, 'google-chrome', 'chromium', 'chromium-browser'].filter(Boolean);
    const browser = candidates.find((name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);
    assert.ok(browser, 'background browser smoke requires Chromium or Google Chrome');
    return browser;
}

async function withServer(wasm, name, visit) {
    const port = await freePort();
    const output = join(work, name);
    const server = spawn(binary, ['run', '--wasm', wasm, '--output-dir', output,
        '--port', String(port), '--no-watch'], { stdio: 'ignore' });
    const exited = new Promise((ok, fail) => {
        server.once('error', fail);
        server.once('close', (code, signal) => ok({ code, signal }));
    });
    const url = `http://127.0.0.1:${port}/`;
    try {
        let ready = false;
        for (let i = 0; i < 200; i++) {
            if (server.exitCode !== null) throw new Error(`dev server exited: ${server.exitCode}`);
            try {
                ready = (await fetch(url, { signal: AbortSignal.timeout(1000) })).ok;
            } catch (error) {
                const retryable = error.cause?.code === 'ECONNREFUSED' ||
                    error.name === 'TimeoutError';
                if (!retryable) throw error;
            }
            if (ready) break;
            await sleep(100);
        }
        assert.ok(ready, 'dev server did not start');
        await visit(url, output);
    } finally {
        await stopServer(server, exited, port);
    }
}

// Virtual time outruns a loaded machine and the GPU process, so pages are polled over DevTools in real time.
async function pollPage(flags, profile, url, expression, done) {
    const chrome = spawn(findBrowser(), [...flags, '--remote-debugging-port=0', `--user-data-dir=${join(work, profile)}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
    try {
        let stderr = '';
        const devtools = await new Promise((ok, fail) => {
            const timer = setTimeout(() => fail(new Error(`browser did not open DevTools\n${stderr}`)), 30000);
            chrome.stderr.on('data', (chunk) => {
                stderr += chunk;
                const found = /DevTools listening on ws:\/\/([^/]+)\//.exec(stderr);
                if (found) { clearTimeout(timer); ok(found[1]); }
            });
        });
        const page = await (await fetch(`http://${devtools}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
        const socket = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((ok, fail) => { socket.onopen = ok; socket.onerror = () => fail(new Error('DevTools socket failed')); });
        const evaluate = () => new Promise((ok) => {
            socket.onmessage = (message) => ok(String(JSON.parse(message.data).result?.result?.value ?? ''));
            socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression } }));
        });
        let seen = '';
        for (let i = 0; i < 300 && !done(seen); i++) {
            await sleep(100);
            seen = await evaluate();
        }
        socket.close();
        return seen;
    } finally {
        chrome.kill();
    }
}

async function browserSmoke(wasm) {
    await withServer(wasm, 'browser', async (url, output) => {
        const index = join(output, 'index.html');
        const html = readFileSync(index, 'utf8');
        const hook = `<script>window.addEventListener('ZunkApplicationStarted', () => {
          document.dispatchEvent(new KeyboardEvent('keydown', {key: 'w', keyCode: 87, bubbles: true}));
          requestAnimationFrame(() => requestAnimationFrame(() => {
            const c = document.querySelector('canvas');
            const p = c.getContext('2d').getImageData(65, 200, 1, 1).data;
            document.body.dataset.smoke = document.title === 'zunk input demo' && p[1] > p[0] ? 'passed' : 'failed';
          }));
        });</script>`;
        assert.ok(html.includes('</head>'), 'generated page has no head');
        writeFileSync(index, html.replace('</head>', `${hook}</head>`));
        const flags = ['--headless', '--no-sandbox', '--disable-gpu', '--disable-software-rasterizer', '--disable-dev-shm-usage'];
        const smoke = await pollPage(flags, 'chrome', url, `document.body?.dataset.smoke ?? ''`, (value) => value !== '');
        assert.equal(smoke, 'passed', 'browser did not start and render the input demo');
        console.log('Browser: dev server, wasm startup and canvas rendering');
    });
}

async function gpuSmoke(wasm) {
    const flags = ['--headless', '--no-sandbox', '--disable-dev-shm-usage', '--ignore-gpu-blocklist', '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--enable-features=Vulkan,WebGPU', '--use-vulkan=swiftshader', '--use-webgpu-adapter=swiftshader', '--use-angle=swiftshader'];
    await withServer(wasm, 'browser-gpu', async (url) => {
        const title = await pollPage(flags, 'chrome-gpu', url, 'document.title', (value) => value.includes('readback'));
        assert.equal(title, 'zunk mesh-3d: readback ok', 'mesh-3d did not draw and read back through WebGPU');
        console.log('Browser: WebGPU frame, resources destroyed before present, readback');
    });
}

if (mode === 'size') {
    const bytes = statSync(binary).size;
    const budget = 64 * 1024 * 1024;
    assert.ok(bytes <= budget, `installed CLI: ${bytes} bytes exceeds ${budget} byte budget`);
    console.log(`Installed CLI: ${bytes} bytes; budget ${budget}`);
} else if (mode === 'serve') {
    await devServerCheck(join(root, 'examples', 'vertex-triangle',
        'zig-out', 'bin', 'vertex-triangle.wasm'));
} else if (mode === 'blocking') {
    console.log(run('zig', [
        'build', 'fuzz', '-j4', `-Dcommit=${commit.stdout.trim()}`, `-Doptimize=${optimize}`,
        '--', '--seed', '1', '--iterations', '512',
    ]));
    const simArgs = ['build', 'sim', '-j4', '-Doptimize=ReleaseSafe', '--',
        '--seed', '1', '--seeds', '32', '--steps', '700'];
    const simFirst = run('zig', simArgs);
    const simSecond = run('zig', simArgs);
    const simHash = (output) => /campaign_hash=([0-9a-f]+)/.exec(output)?.[1];
    assert.match(simFirst, /failures=0 /, simFirst);
    assert.ok(simHash(simFirst), 'simulation printed no campaign hash');
    assert.equal(simHash(simFirst), simHash(simSecond), 'simulation trace hash differs between two processes');
    console.log(`Blocking: dev-server simulation, 32 seeds, hash ${simHash(simFirst)} in two processes`);
    assert.match(run(binary, ['version']), /\d+\.\d+\.\d+/);
    assert.match(run(binary, ['help']), /deploy/);
    const wasm = example('vertex-triangle');
    const output = join(work, 'deploy');
    run(binary, ['deploy', '--wasm', wasm, '--output-dir', output]);
    const html = readFileSync(join(output, 'index.html'), 'utf8');
    const files = readdirSync(output);
    assert.ok(files.some((f) => f.endsWith('.wasm') && html.includes(f)), 'deploy wasm is not referenced');
    assert.ok(files.some((f) => f.endsWith('.js') && html.includes(f)), 'deploy JS is not referenced');
    assert.ok(files.some((f) => f.endsWith('.wasm') && WebAssembly.validate(readFileSync(join(output, f)))));
    console.log('Blocking: CLI build, version, help, example build, deploy');
    await devServerCheck(wasm);
} else if (mode === 'browser') {
    await browserSmoke(join(root, 'examples', 'input-demo', 'zig-out', 'bin', 'input-demo.wasm'));
} else if (mode === 'heavy') {
    const wasms = {};
    for (const name of ['input-demo', 'text-demo', 'mesh-3d', 'audio-demo-1-assets-bundled', 'texture-demo', 'particle-life']) {
        wasms[name] = example(name);
        console.log(`Built ${name}`);
    }
    const inputWasm = wasms['input-demo'];
    const font = join(work, 'example-font.ttf');
    writeFileSync(font, 'font fixture');
    const withFont = join(work, 'with-font');
    run(binary, ['build', '--wasm', inputWasm, '--output-dir', withFont, '--font', 'Example', '400', font]);
    assert.equal(readFileSync(join(withFont, 'fonts', 'example-font.ttf'), 'utf8'), 'font fixture');
    const invalidFont = join(work, 'invalid-font');
    run(binary, ['build', '--wasm', inputWasm, '--output-dir', invalidFont, '--font', 'Example', 'bold', font]);
    assert.ok(!existsSync(invalidFont), 'invalid font weight should prevent output');
    console.log('CLI: font asset and invalid weight');
    const report = JSON.parse(run(binary, ['build', '--wasm', inputWasm, '--output-dir', join(work, 'report'), '--report-json']));
    assert.equal(report.stubs, 0, 'input-demo has unresolved imports');
    assert.equal(report.resolutions.length, report.total_imports);
    console.log('CLI: JSON build report');
    await browserSmoke(inputWasm);
    await gpuSmoke(wasms['mesh-3d']);
} else {
    throw new Error(`unknown gate: ${mode}`);
}
