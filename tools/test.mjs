import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

const [mode, binary] = process.argv.slice(2);
const root = resolve('.');
const work = mkdtempSync(join(root, '.zig-cache', 'e2e-'));

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

function findBrowser() {
    const candidates = [process.env.CHROME_BIN, 'google-chrome', 'chromium', 'chromium-browser'].filter(Boolean);
    const browser = candidates.find((name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);
    assert.ok(browser, 'background browser smoke requires Chromium or Google Chrome');
    return browser;
}

async function withServer(wasm, name, visit) {
    const probe = createServer();
    await new Promise((ok, fail) => probe.once('error', fail).listen(0, '127.0.0.1', ok));
    const port = probe.address().port;
    await new Promise((ok, fail) => probe.close((err) => err ? fail(err) : ok()));
    const output = join(work, name);
    const server = spawn(binary, ['run', '--wasm', wasm, '--output-dir', output, '--port', String(port), '--no-watch'], { stdio: 'ignore' });
    const url = `http://127.0.0.1:${port}/`;
    try {
        let ready = false;
        for (let i = 0; i < 200; i++) {
            if (server.exitCode !== null) throw new Error(`dev server exited: ${server.exitCode}`);
            try { ready = (await fetch(url)).ok; } catch {}
            if (ready) break;
            await sleep(100);
        }
        assert.ok(ready, 'dev server did not start');
        await visit(url, output);
    } finally {
        server.kill();
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

if (mode === 'blocking') {
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
