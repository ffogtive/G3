// Small JS source helpers for the one-time web export (no parser dependency; the repo has none installed).
//
// - scanStrings(src): tokenizes JS (comments, strings, template literals with nesting, regex literals) and returns
//   every string/template literal with its line, the innermost call it is an argument of, and its enclosing array.
// - extractConst(src, name): returns the source text of the initializer of `const NAME = <expr>;` (bracket matched).
// - evalLiteral(text, sandbox): evaluates an initializer in an isolated node:vm context.
import vm from 'node:vm';

const HANGUL = /[ㄱ-ㆎ가-힣]/;
export const hasHangul = (s) => HANGUL.test(s);

const REGEX_PRECEDERS = new Set(['(', '[', '{', ',', ';', ':', '?', '=', '!', '&', '|', '+', '-', '*', '%', '^', '~', '<', '>', '=>']);
const REGEX_KEYWORDS = new Set(['return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'new', 'delete', 'void', 'throw', 'yield', 'await']);

/**
 * @returns {{ literals: Array<{start:number,end:number,line:number,kind:'string'|'template',text:string,callee:string|null,arrayStart:number|null,prop:string|null}> }}
 */
export function scanStrings(src) {
  const literals = [];
  let i = 0, line = 1;
  // bracket stack entries: { ch, callee, start }
  const stack = [];
  let prevSig = null;       // previous significant token text
  let prevIdentChain = '';  // identifier chain immediately before (e.g. 'ui.toast?.') for call detection
  const lineAt = (pos) => { let n = 1; for (let k = 0; k < pos; k++) if (src.charCodeAt(k) === 10) n++; return n; };
  const top = () => stack[stack.length - 1];
  const innermostCall = () => { for (let k = stack.length - 1; k >= 0; k--) if (stack[k].ch === '(') return stack[k].callee; return null; };
  const pushLiteral = (start, end, kind, text) => {
    const t = top();
    literals.push({
      start, end, line: lineAt(start), kind, text,
      callee: innermostCall(),
      arrayStart: t && t.ch === '[' ? t.start : null,
      prop: t && t.ch === '{' && lastProp ? lastProp : null,
    });
  };
  let lastProp = null;  // identifier followed by ':' inside an object literal
  let pendingIdent = null;

  function readString(q) {
    const start = i; i++;
    let out = '';
    while (i < src.length && src[i] !== q) {
      if (src[i] === '\\') {
        const n = src[i + 1];
        const map = { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', v: '\v', 0: '\0' };
        if (n in map) { out += map[n]; i += 2; continue; }
        if (n === 'u') {
          if (src[i + 2] === '{') { const j = src.indexOf('}', i); out += String.fromCodePoint(parseInt(src.slice(i + 3, j), 16)); i = j + 1; continue; }
          out += String.fromCharCode(parseInt(src.slice(i + 2, i + 6), 16)); i += 6; continue;
        }
        if (n === 'x') { out += String.fromCharCode(parseInt(src.slice(i + 2, i + 4), 16)); i += 4; continue; }
        if (n === '\n') { i += 2; continue; }
        out += n; i += 2; continue;
      }
      out += src[i]; i++;
    }
    i++;
    return { start, end: i, text: out };
  }

  // template literal; returns raw text with ${...} spans copied verbatim. Nested code inside ${} is scanned too.
  function readTemplate() {
    const start = i; i++;
    let raw = '';
    while (i < src.length && src[i] !== '`') {
      if (src[i] === '\\') { raw += src[i] + src[i + 1]; i += 2; continue; }
      if (src[i] === '$' && src[i + 1] === '{') {
        const exprStart = i + 2;
        i += 2;
        scanCode('}');            // consumes through matching '}'
        raw += '${' + src.slice(exprStart, i - 1) + '}';
        continue;
      }
      raw += src[i]; i++;
    }
    i++;
    return { start, end: i, text: raw };
  }

  function readRegex() {
    i++;
    let inClass = false;
    while (i < src.length) {
      const c = src[i];
      if (c === '\\') { i += 2; continue; }
      if (c === '[') inClass = true;
      else if (c === ']') inClass = false;
      else if (c === '/' && !inClass) { i++; break; }
      else if (c === '\n') throw new Error(`unterminated regex near line ${lineAt(i)}`);
      i++;
    }
    while (/[a-z]/i.test(src[i] || '')) i++;
  }

  // scans code until `terminator` (a closing char at depth 0 of this call) or EOF
  function scanCode(terminator) {
    const base = stack.length;
    while (i < src.length) {
      const c = src[i], n = src[i + 1];
      if (c === '\n') { line++; i++; continue; }
      if (c === ' ' || c === '\t' || c === '\r') { i++; continue; }
      if (c === '/' && n === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
      if (c === '/' && n === '*') { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; continue; }
      if (c === '"' || c === "'") {
        const s = readString(c); pushLiteral(s.start, s.end, 'string', s.text);
        prevSig = 'str'; prevIdentChain = ''; lastProp = null; continue;
      }
      if (c === '`') {
        const s = readTemplate(); pushLiteral(s.start, s.end, 'template', s.text);
        prevSig = 'str'; prevIdentChain = ''; lastProp = null; continue;
      }
      if (c === '/') {
        const regexOk = prevSig === null || REGEX_PRECEDERS.has(prevSig) || REGEX_KEYWORDS.has(prevSig);
        if (regexOk) { readRegex(); prevSig = 'regex'; prevIdentChain = ''; continue; }
        i++; prevSig = '/'; prevIdentChain = ''; continue;
      }
      if (/[A-Za-z_$\u0080-￿]/.test(c)) {
        let j = i; while (j < src.length && /[\w$\u0080-￿]/.test(src[j])) j++;
        const id = src.slice(i, j);
        prevIdentChain = (prevSig === '.' || prevSig === '?.') ? prevIdentChain + id : id;
        pendingIdent = id;
        prevSig = id; i = j; continue;
      }
      if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(n || ''))) {
        let j = i + 1; while (j < src.length && /[\w.]/.test(src[j])) j++;
        i = j; prevSig = 'num'; prevIdentChain = ''; continue;
      }
      if (c === '?' && n === '.' && !/[0-9]/.test(src[i + 2] || '')) {
        i += 2; prevIdentChain += '?.'; prevSig = '?.'; continue;
      }
      if (c === '.' && n === '.' && src[i + 2] === '.') { i += 3; prevSig = '...'; prevIdentChain = ''; continue; }
      if (c === '.') { i++; prevIdentChain += '.'; prevSig = '.'; continue; }
      if (c === '=' && n === '>') { i += 2; prevSig = '=>'; prevIdentChain = ''; continue; }
      if (c === '(' || c === '[' || c === '{') {
        const callee = c === '(' && prevSig && /^[\w$\u0080-￿]+$/.test(prevSig) && !REGEX_KEYWORDS.has(prevSig) && !['if', 'for', 'while', 'switch', 'catch', 'function'].includes(prevSig)
          ? prevIdentChain : (c === '(' && prevSig === '?.' ? prevIdentChain.replace(/\?\.$/, '') : null);
        stack.push({ ch: c, callee, start: i });
        i++; prevSig = c; prevIdentChain = ''; lastProp = null; continue;
      }
      if (c === ')' || c === ']' || c === '}') {
        if (stack.length === base && c === terminator) { i++; return; }
        stack.pop();
        i++; prevSig = c; prevIdentChain = ''; lastProp = null; continue;
      }
      if (c === ':') {
        const t = top();
        if (t && t.ch === '{' && pendingIdent && prevSig === pendingIdent) lastProp = pendingIdent;
        i++; prevSig = ':'; prevIdentChain = ''; continue;
      }
      if (c === ',') { i++; prevSig = ','; prevIdentChain = ''; if (top()?.ch === '{') lastProp = null; continue; }
      // other punctuators / operators (take longest common ones as single chars; only the class matters)
      i++; prevSig = c; prevIdentChain = '';
    }
  }
  scanCode(null);
  return { literals };
}

/** Source text of the initializer of `const NAME = ...;` / `export const NAME = ...;` (balanced brackets). */
export function extractConst(src, name) {
  const re = new RegExp(`(?:^|\\n)\\s*(?:export\\s+)?const\\s+${name}\\s*=\\s*`);
  const m = re.exec(src);
  if (!m) throw new Error(`extractConst: ${name} not found`);
  let i = m.index + m[0].length;
  const start = i;
  let depth = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === '`') {
      const q = c; i++;
      while (i < src.length && src[i] !== q) {
        if (src[i] === '\\') i++;
        else if (q === '`' && src[i] === '$' && src[i + 1] === '{') {
          // skip ${...} (no nested templates expected in data tables)
          let d = 1; i += 2;
          while (i < src.length && d) { if (src[i] === '{') d++; else if (src[i] === '}') d--; i++; }
          continue;
        }
        i++;
      }
      i++; continue;
    }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
    if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i + 2) + 2; continue; }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === ';' && depth === 0) return src.slice(start, i);
    else if (c === '\n' && depth === 0 && src.slice(start, i).trim()) return src.slice(start, i);
    i++;
  }
  throw new Error(`extractConst: unterminated ${name}`);
}

export function evalLiteral(text, sandbox = {}) {
  const ctx = vm.createContext({ ...sandbox });
  return vm.runInContext(`(${text})`, ctx, { timeout: 1000 });
}

/** 1-based line of the first match of `needle` (string or RegExp) in src, else throws. */
export function lineOf(src, needle, from = 0) {
  const idx = typeof needle === 'string' ? src.indexOf(needle, from) : src.slice(from).search(needle) + (src.slice(from).search(needle) >= 0 ? from : 0);
  if (idx < 0 || (typeof needle !== 'string' && src.slice(from).search(needle) < 0)) throw new Error(`lineOf: not found ${needle}`);
  return src.slice(0, idx).split('\n').length;
}
