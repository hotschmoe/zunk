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

async function browserSmoke(wasm) {
    const candidates = [process.env.CHROME_BIN, 'google-chrome', 'chromium', 'chromium-browser'].filter(Boolean);
    const browser = candidates.find((name) => spawnSync(name, ['--version'], { stdio: 'ignore' }).status === 0);
    assert.ok(browser, 'background browser smoke requires Chromium or Google Chrome');

    const probe = createServer();
    await new Promise((ok, fail) => probe.once('error', fail).listen(0, '127.0.0.1', ok));
    const port = probe.address().port;
    await new Promise((ok, fail) => probe.close((err) => err ? fail(err) : ok()));
    const output = join(work, 'browser');
    const server = spawn(binary, ['run', '--wasm', wasm, '--output-dir', output, '--port', String(port), '--no-watch'], { stdio: 'ignore' });
    const url = `http://127.0.0.1:${port}/`;
    try {
        let ready = false;
        for (let i = 0; i < 200; i++) {
            if (server.exitCode !== null) throw new Error(`dev server exited: ${server.exitCode}`);
            try { ready = (await fetch(url)).ok; } catch {}
            if (ready) break;
            await new Promise((ok) => setTimeout(ok, 100));
        }
        assert.ok(ready, 'dev server did not start');
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
        const page = run(browser, ['--headless', '--no-sandbox', '--disable-gpu', '--disable-software-rasterizer', '--disable-dev-shm-usage', '--virtual-time-budget=5000', `--user-data-dir=${join(work, 'chrome')}`, '--dump-dom', url], root, 30000);
        assert.match(page, /data-smoke="passed"/, 'browser did not start and render the input demo');
        console.log('Browser: dev server, wasm startup and canvas rendering');
    } finally {
        server.kill();
    }
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
    let inputWasm;
    for (const name of ['input-demo', 'text-demo', 'mesh-3d', 'audio-demo-1-assets-bundled', 'texture-demo', 'particle-life']) {
        const wasm = example(name);
        if (name === 'input-demo') inputWasm = wasm;
        console.log(`Built ${name}`);
    }
    const font = join(work, 'example-font.ttf');
    writeFileSync(font, 'font fixture');
    const withFont = join(work, 'with-font');
    run(binary, ['build', '--wasm', inputWasm, '--output-dir', withFont, '--font', 'Example', '400', font]);
    assert.equal(readFileSync(join(withFont, 'fonts', 'example-font.ttf'), 'utf8'), 'font fixture');
    const invalidFont = join(work, 'invalid-font');
    run(binary, ['build', '--wasm', inputWasm, '--output-dir', invalidFont, '--font', 'Example', 'bold', font]);
    assert.ok(!existsSync(invalidFont), 'invalid font weight should prevent output');
    console.log('CLI: font asset and invalid weight');
    await browserSmoke(inputWasm);
} else {
    throw new Error(`unknown gate: ${mode}`);
}
