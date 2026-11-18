import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

const [mode, binary] = process.argv.slice(2);
const root = resolve('.');
const work = mkdtempSync(join(root, '.zig-cache', 'e2e-'));

function run(command, args, cwd = root) {
    const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
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
} else if (mode === 'heavy') {
    for (const name of ['input-demo', 'text-demo', 'mesh-3d', 'audio-demo-1-assets-bundled', 'texture-demo', 'particle-life']) {
        example(name);
        console.log(`Built ${name}`);
    }
} else {
    throw new Error(`unknown gate: ${mode}`);
}
