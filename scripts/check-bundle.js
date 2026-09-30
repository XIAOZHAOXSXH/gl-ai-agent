/**
 * Verify the built view bundle satisfies the SDK4 loader contract, locally.
 *
 * GL's router does:  component = eval(await axios.get('.../gl-sdk4-ui-X.common.js'))
 * so the *value of the evaluated program* must be the component object.
 * This script reproduces that in a sandbox and fails loudly otherwise.
 *
 *   node scripts/check-bundle.js
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const BUNDLE = path.resolve(
    __dirname,
    '../package/data/www/views/gl-sdk4-ui-gl-ai.common.js'
);

function fail(msg) {
    console.error(`FAIL  ${msg}`);
    process.exit(1);
}

if (!fs.existsSync(BUNDLE)) fail(`${BUNDLE} not found - run: node scripts/build-ui.js`);
const code = fs.readFileSync(BUNDLE, 'utf8');

// Minimal browser-ish globals the bundle touches at load time. vue-style-loader
// runs in the bundle's own top-level code, so these must exist before it
// evaluates. check-eval-contract.js verifies the same thing in a real browser;
// this is the fast offline equivalent.
function makeElement() {
    const el = {
        style: {},
        dataset: {},
        children: [],
        childNodes: [],
        classList: { add() {}, remove() {}, contains: () => false },
        setAttribute() {},
        removeAttribute() {},
        getAttribute: () => null,
        appendChild(c) { el.children.push(c); el.childNodes.push(c); return c; },
        insertBefore(c) { el.children.unshift(c); el.childNodes.unshift(c); return c; },
        removeChild() {},
        addEventListener() {},
        removeEventListener() {},
        cloneNode: () => makeElement(),
        querySelector: () => null,
        querySelectorAll: () => [],
        getElementsByTagName: () => [],
        contains: () => false,
    };
    return el;
}

const sandbox = {
    document: {
        head: makeElement(),
        body: makeElement(),
        documentElement: makeElement(),
        createElement: () => makeElement(),
        createTextNode: (t) => ({ nodeValue: t, textContent: t }),
        createComment: (t) => ({ nodeValue: t }),
        querySelector: () => null,
        querySelectorAll: () => [],
        getElementById: () => null,
        getElementsByTagName: () => [],
        addEventListener: () => {},
        removeEventListener: () => {},
        readyState: 'complete',
    },
    navigator: {
        language: 'en',
        languages: ['en'],
        userAgent: 'Mozilla/5.0 (check-bundle)',
        platform: 'Linux',
    },
    location: { href: 'http://192.168.8.1/', hash: '', protocol: 'http:', host: '192.168.8.1' },
    localStorage: {
        _d: {},
        getItem(k) { return this._d[k] === undefined ? null : this._d[k]; },
        setItem(k, v) { this._d[k] = String(v); },
        removeItem(k) { delete this._d[k]; },
    },
    sessionStorage: {
        _d: {},
        getItem(k) { return this._d[k] === undefined ? null : this._d[k]; },
        setItem(k, v) { this._d[k] = String(v); },
        removeItem(k) { delete this._d[k]; },
    },
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    fetch: () => new Promise(() => {}),
    addEventListener: () => {},
    removeEventListener: () => {},
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    matchMedia: () => ({ matches: false, addListener() {}, removeListener() {} }),
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.document.defaultView = sandbox;
// the SDK evals the bundle at global scope; `module` resolves via a shim there
sandbox.module = { exports: {} };

let component;
try {
    component = vm.runInNewContext(code, sandbox, { timeout: 10000 });
} catch (e) {
    fail(`bundle threw while evaluating: ${e.message}`);
}

// ---- contract checks -----------------------------------------------------
const problems = [];

if (!component || typeof component !== 'object') {
    problems.push(`eval() returned ${typeof component}, expected the component object`);
} else {
    if (typeof component.name !== 'string' || !component.name) {
        problems.push('component.name is missing');
    }
    if (typeof component.data !== 'function') {
        problems.push('component.data is not a function');
    }
    if (typeof component.methods !== 'object' || !component.methods) {
        problems.push('component.methods is missing');
    }
    // GL's Vue is runtime-only: a raw `template` string would never compile.
    if (typeof component.template === 'string') {
        problems.push('component still carries a string template - render function missing');
    }
    if (typeof component.render !== 'function') {
        problems.push('component.render is not a function');
    }
    // a Module/exports wrapper is the classic wrong shape
    if ('exports' in component && Object.keys(component).length <= 2) {
        problems.push('bundle returned a Module wrapper instead of the component');
    }
}

if (problems.length) {
    console.error('FAIL  bundle does not satisfy the SDK4 view contract:');
    problems.forEach((p) => console.error(`        - ${p}`));
    process.exit(1);
}

console.log('OK    bundle satisfies the SDK4 loader contract');
console.log(`      eval() -> component "${component.name}"`);
console.log(`      render: ${typeof component.render}, template: ${typeof component.template}`);
console.log(`      bytes:  ${code.length}, gz: ${
    fs.existsSync(BUNDLE + '.gz') ? fs.statSync(BUNDLE + '.gz').size : 'missing'
}`);
