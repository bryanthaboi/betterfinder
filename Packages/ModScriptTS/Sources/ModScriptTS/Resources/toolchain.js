function bfCompile(request, lib, emit) {
    const diagnostics = [];
    const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
    const files = Object.create(null);
    function diagnostic(code, message, source, node) {
        const pos = source && node ? source.getLineAndCharacterOfPosition(node.getStart(source)) : null;
        diagnostics.push({code, message, file: source ? source.fileName.replace(/^\//, '') : null,
            line: pos ? pos.line + 1 : null, col: pos ? pos.character + 1 : null, category: 'error'});
    }
    function validPath(path) {
        return typeof path === 'string' && path.length > 0 && !path.startsWith('/') && !path.includes('\\') &&
            !path.includes('\0') && path.split('/').every(p => p !== '..' && p !== '.' && p !== '');
    }
    for (const name of Object.keys(request.files).sort()) {
        if (name === '__bf_hook_check.ts' || name === 'betterfinder.d.ts' || !validPath(name) || !/\.(ts|js|mjs)$/.test(name) || /\.d\.ts$/.test(name)) {
            diagnostic(90001, 'Invalid package source path: ' + name); continue;
        }
        if (request.language === 'js' && /\.ts$/.test(name)) diagnostic(90001, 'TS source in JS package: ' + name);
        if (/@ts-(ignore|nocheck|expect-error)\b/.test(request.files[name])) diagnostic(90002, 'Type-check suppression is forbidden: ' + name);
        files['/' + name] = request.files[name];
    }
    if (!validPath(request.entry) || !Object.hasOwn(files, '/' + request.entry)) diagnostic(90001, 'Entry source is missing or invalid');
    function resolve(specifier, containing) {
        if (specifier === 'betterfinder') return '/betterfinder.d.ts';
        if (specifier.startsWith('/') || specifier.includes('\\') || specifier.includes('\0')) return null;
        const parts = specifier.startsWith('.') ? containing.split('/').slice(0, -1) : [''];
        for (const part of specifier.split('/')) {
            if (part === '.' || part === '') continue;
            if (part === '..') { if (parts.length <= 1) return null; parts.pop(); }
            else parts.push(part);
        }
        const base = parts.join('/');
        const candidates = [base, base + '.ts', base + '.js', base + '.mjs', base + '/index.ts', base + '/index.js'];
        if (/\.(js|mjs)$/.test(base)) candidates.push(base.replace(/\.(js|mjs)$/, '.ts'));
        return candidates.find(p => Object.hasOwn(files, p)) || null;
    }
    files['/betterfinder.d.ts'] = request.declarations;
    files['/lib.es2020.betterfinder.d.ts'] = lib;
    const roots = Object.keys(files).sort();
    const options = {strict: true, noImplicitAny: true, isolatedModules: true, noEmitOnError: true,
        moduleDetection: ts.ModuleDetectionKind.Force, module: ts.ModuleKind.ES2020, target: ts.ScriptTarget.ES2020, allowJs: true, checkJs: true,
        noLib: true, types: [], allowNonTsExtensions: true, outDir: "/__bf_emit"};
    const host = {
        getSourceFile: (path, version) => Object.hasOwn(files, path) ? ts.createSourceFile(path, files[path], version, true) : undefined,
        getDefaultLibFileName: () => '/lib.es2020.betterfinder.d.ts', writeFile: () => {},
        getCurrentDirectory: () => '/', getDirectories: () => [], fileExists: path => Object.hasOwn(files, path),
        readFile: path => files[path], getCanonicalFileName: path => path, useCaseSensitiveFileNames: () => true,
        getNewLine: () => '\n', resolveModuleNames: (names, containing) => names.map(name => {
            const path = resolve(name, containing);
            return path ? {resolvedFileName: path, extension: path.endsWith('.d.ts') ? ts.Extension.Dts : path.endsWith('.ts') ? ts.Extension.Ts : ts.Extension.Js} : undefined;
        })
    };
    const program = ts.createProgram(roots, options, host);
    function memberName(node) {
        if (ts.isPropertyAccessExpression(node)) return node.name.text;
        if (ts.isElementAccessExpression(node) && node.argumentExpression && ts.isStringLiteralLike(node.argumentExpression)) return node.argumentExpression.text;
        return null;
    }
    function walk(source, node) {
        if (ts.isIdentifier(node) && ['eval', 'Function', 'require', 'globalThis'].includes(node.text)) diagnostic(90002, 'Forbidden identifier: ' + node.text, source, node);
        const member = memberName(node);
        if (['eval', 'Function', 'require', '__proto__', 'prototype', 'constructor', 'setPrototypeOf', 'defineProperty', 'defineProperties'].includes(member))
            diagnostic(90002, 'Forbidden property: ' + member, source, node);
        if (ts.isWithStatement(node)) diagnostic(90002, 'with is forbidden', source, node);
        if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) diagnostic(90002, 'Dynamic import is forbidden', source, node);
        if (ts.isImportEqualsDeclaration(node)) diagnostic(90002, 'Import assignment is forbidden', source, node);
        if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) {
            if (!ts.isStringLiteralLike(node.moduleSpecifier) || !resolve(node.moduleSpecifier.text, source.fileName))
                diagnostic(90003, 'Import must resolve inside the package or to betterfinder', source, node);
        }
        if (ts.isAwaitExpression(node) || (ts.isForOfStatement(node) && node.awaitModifier)) {
            let parent = node.parent;
            while (parent && !ts.isFunctionLike(parent)) parent = parent.parent;
            if (!parent) diagnostic(90002, 'Top-level await is forbidden', source, node);
        }
        if (ts.isBinaryExpression(node) && node.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && node.operatorToken.kind <= ts.SyntaxKind.LastAssignment ||
            ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node) || ts.isDeleteExpression(node)) {
            const target = ts.isBinaryExpression(node) ? node.left : node.operand || node.expression;
            if (target && /\bglobalThis\b/.test(target.getText(source))) diagnostic(90002, 'globalThis mutation is forbidden', source, node);
        }
        ts.forEachChild(node, child => walk(source, child));
    }
    for (const source of program.getSourceFiles()) if (!source.isDeclarationFile) walk(source, source);
    const checker = program.getTypeChecker();
    const analysis = analyzeCatalog();
    function analyzeCatalog() {
        const BF = '/betterfinder.d.ts';
        const calls = [];
        const escapes = [];
        const callNames = request.callNames || {};
        function catalogDecl(node) {
            if (!node) return null;
            let sym = checker.getSymbolAtLocation(node);
            if (sym && (sym.flags & ts.SymbolFlags.Alias)) sym = checker.getAliasedSymbol(sym);
            if (!sym || !sym.declarations) return null;
            return sym.declarations.find(d => d.getSourceFile().fileName === BF && isCatalogMember(d)) || null;
        }
        function isCatalogMember(decl) {
            for (let n = decl; n && !ts.isSourceFile(n); n = n.parent) {
                if (ts.isInterfaceDeclaration(n) || ts.isTypeAliasDeclaration(n) || ts.isEnumDeclaration(n)) return false;
            }
            if (ts.isFunctionDeclaration(decl) || ts.isModuleDeclaration(decl) || ts.isVariableDeclaration(decl)) return true;
            let n = decl;
            while (n && (ts.isMethodSignature(n) || ts.isPropertySignature(n)) && n.parent && ts.isTypeLiteralNode(n.parent)) {
                const owner = n.parent.parent;
                if (owner && ts.isVariableDeclaration(owner)) return true;
                n = owner;
            }
            return false;
        }
        function declName(decl) {
            const parts = [];
            for (let node = decl; node && !ts.isSourceFile(node); node = node.parent) {
                if (ts.isModuleDeclaration(node)) {
                    if (ts.isStringLiteral(node.name)) break;
                    parts.unshift(node.name.text);
                } else if ((ts.isFunctionDeclaration(node) || ts.isMethodSignature(node) || ts.isPropertySignature(node) || ts.isVariableDeclaration(node)) &&
                    node.name && (ts.isIdentifier(node.name) || ts.isStringLiteralLike(node.name))) {
                    parts.unshift(node.name.text);
                }
            }
            return parts.join('.');
        }
        function target(node) {
            if (ts.isIdentifier(node)) return node;
            if (ts.isPropertyAccessExpression(node)) return node.name;
            if (ts.isElementAccessExpression(node) && node.argumentExpression && ts.isStringLiteralLike(node.argumentExpression)) return node.argumentExpression;
            return null;
        }
        function position(source, node) {
            const pos = source.getLineAndCharacterOfPosition(node.getStart(source));
            return {line: pos.line + 1, col: pos.character + 1};
        }
        function inTypeOrImport(node) {
            for (let n = node.parent; n; n = n.parent) {
                if (ts.isTypeNode(n) && !ts.isExpressionWithTypeArguments(n)) return true;
                if (ts.isImportSpecifier(n) || ts.isImportClause(n) || ts.isNamespaceImport(n) || ts.isImportEqualsDeclaration(n) || ts.isImportDeclaration(n)) return true;
                if ((n.kind >= ts.SyntaxKind.FirstStatement && n.kind <= ts.SyntaxKind.LastStatement) || ts.isSourceFile(n)) return false;
            }
            return false;
        }
        function escape(source, node, reason) {
            const p = position(source, node);
            escapes.push({file: source.fileName.replace(/^\//, ''), line: p.line, col: p.col, reason});
        }
        function visit(source, node) {
            if (ts.isCallExpression(node)) {
                const callee = ts.skipParentheses(node.expression);
                const t = target(callee);
                const decl = t && catalogDecl(t);
                if (decl) {
                    const name = declName(decl);
                    const p = position(source, node);
                    const call = {name, catalogName: Object.hasOwn(callNames, name) ? callNames[name] : name,
                        file: source.fileName.replace(/^\//, ''), line: p.line, col: p.col, rootID: null, rootLine: null, rootCol: null, dynamicRoot: false};
                    const index = (decl.parameters || []).findIndex(q => ts.isIdentifier(q.name) && q.name.text.replace(/_$/, '') === 'rootId');
                    const arg = index >= 0 ? node.arguments[index] : undefined;
                    if (arg) {
                        if (ts.isStringLiteralLike(arg)) {
                            const rp = position(source, arg);
                            call.rootID = arg.text; call.rootLine = rp.line; call.rootCol = rp.col;
                        } else call.dynamicRoot = true;
                    }
                    calls.push(call);
                }
            }
            if (ts.isIdentifier(node) || ts.isPropertyAccessExpression(node) || (ts.isElementAccessExpression(node) && target(node))) {
                const parent = node.parent;
                const outermost = !(parent && (ts.isPropertyAccessExpression(parent) || ts.isElementAccessExpression(parent)) && parent.expression === node);
                const isCallee = parent && ts.isCallExpression(parent) && parent.expression === node;
                const isName = parent && ((ts.isPropertyAccessExpression(parent) && parent.name === node) || ts.isExportSpecifier(parent));
                if (outermost && !isCallee && !isName && !inTypeOrImport(node) && catalogDecl(target(node))) {
                    escape(source, node, 'catalog member used as a value instead of being called directly');
                }
            }
            if (ts.isElementAccessExpression(node) && !target(node)) {
                const base = target(node.expression);
                if (base && catalogDecl(base)) escape(source, node, 'computed property access on a catalog namespace');
            }
            if (ts.isExportSpecifier(node) && !node.parent.parent.isTypeOnly && !node.isTypeOnly) {
                const decl = catalogDecl(node.propertyName || node.name);
                if (decl) escape(source, node, 're-exporting a catalog member hides calls from analysis');
            }
            if (ts.isExportDeclaration(node) && !node.isTypeOnly && node.moduleSpecifier && ts.isStringLiteralLike(node.moduleSpecifier) && node.moduleSpecifier.text === 'betterfinder') {
                escape(source, node, 're-exporting from betterfinder hides calls from analysis');
            }
            ts.forEachChild(node, child => visit(source, child));
        }
        for (const source of program.getSourceFiles()) if (!source.isDeclarationFile) visit(source, source);
        const order = (a, b) => compare(a.file, b.file) || a.line - b.line || a.col - b.col;
        calls.sort((a, b) => order(a, b) || compare(a.name, b.name));
        escapes.sort((a, b) => order(a, b) || compare(a.reason, b.reason));
        return {calls, escapes};
    }
    const entrySource = program.getSourceFile('/' + request.entry);
    const symbol = entrySource && checker.getSymbolAtLocation(entrySource);
    const exports = symbol ? checker.getExportsOfModule(symbol).map(s => s.name).sort() : [];
    const handlerMap = Object.create(null);
    const hooks = new Map(request.hooks.map(h => [h.name, h]));
    let checks = '';
    for (const name of Object.keys(request.handlers).sort()) {
        const handler = request.handlers[name];
        if (!hooks.has(name) || !exports.includes(handler)) { diagnostic(90004, 'Unknown hook or missing handler export: ' + name + ' -> ' + handler); continue; }
        handlerMap[name] = handler;
        checks += 'const h' + Object.keys(handlerMap).length + ': import("betterfinder").' + hooks.get(name).handlerType + ' = entry[' + JSON.stringify(handler) + '];\n';
    }
    if (checks) {
        files['/__bf_hook_check.ts'] = 'import * as entry from ' + JSON.stringify('./' + request.entry.replace(/\.(ts|js|mjs)$/, '')) + ';\n' + checks;
        const hookProgram = ts.createProgram(Object.keys(files).sort(), options, host);
        appendDiagnostics(ts.getPreEmitDiagnostics(hookProgram));
    } else appendDiagnostics(ts.getPreEmitDiagnostics(program));
    function appendDiagnostics(values) {
        for (const d of values) {
            const pos = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : null;
            diagnostics.push({code: d.code, file: d.file ? d.file.fileName.replace(/^\//, '') : null,
                line: pos ? pos.line + 1 : null, col: pos ? pos.character + 1 : null,
                message: ts.flattenDiagnosticMessageText(d.messageText, '\n'), category: ['warning', 'error', 'suggestion', 'message'][d.category]});
        }
    }
    diagnostics.sort((a,b) => compare(a.file || '', b.file || '') || (a.line || 0)-(b.line || 0) || (a.col || 0)-(b.col || 0) || a.code-b.code || compare(a.message, b.message));
    const result = {diagnostics, handlerExports: handlerMap, moduleSource: null, executionSource: null, calls: analysis.calls, escapes: analysis.escapes};
    if (!emit || diagnostics.some(d => d.category === 'error')) return result;
    if (exports.some(name => name !== 'default' && !/^[A-Za-z_$][\w$]*$/.test(name))) {
        diagnostic(90004, 'Non-identifier exports are unsupported'); return result;
    }
    const factories = [];
    const resolutions = {};
    for (const source of program.getSourceFiles().filter(s => !s.isDeclarationFile).sort((a,b) => compare(a.fileName, b.fileName))) {
        const code = ts.transpileModule(source.text, {compilerOptions: {...options, noEmitOnError: false, module: ts.ModuleKind.CommonJS}, fileName: source.fileName.replace(/\.mjs$/, '.js')}).outputText;
        factories.push(JSON.stringify(source.fileName) + ': function(module, exports, require) {\n' + code + '\n}');
        const mapping = Object.create(null);
        function imports(node) {
            if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) mapping[node.moduleSpecifier.text] = resolve(node.moduleSpecifier.text, source.fileName);
            ts.forEachChild(node, imports);
        }
        imports(source); resolutions[source.fileName] = mapping;
    }
    const expression = '(function(__bf) {"use strict";\nconst factories = {' + factories.join(',\n') + '};\nconst paths = ' + JSON.stringify(resolutions) + ';\nconst cache = Object.create(null);\nfunction load(id) { if (id === "/betterfinder.d.ts") return __bf; if (cache[id]) return cache[id].exports; if (!Object.prototype.hasOwnProperty.call(factories,id)) throw new Error("Unknown module"); const module = {exports:Object.create(null)}; cache[id] = module; factories[id](module,module.exports,spec => load(paths[id][spec])); return module.exports; }\nreturn load(' + JSON.stringify('/' + request.entry) + ');\n})(__bf)';
    result.executionSource = expression;
    result.moduleSource = 'const __bf_entry = ' + expression + ';\n' + exports.map((name,i) => 'const __bf_export' + i + ' = __bf_entry[' + JSON.stringify(name) + '];\nexport { __bf_export' + i + ' as ' + name + ' };').join('\n') + '\n';
    return result;
}
