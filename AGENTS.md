# Wellout coding conventions

## Scope

Wellout is framework-independent. Code under `src/wellout` must not import hxwell, HaxePress or other application packages. Framework adapters live in their own packages or repositories.

## Imports and style

- Import types from other packages explicitly and use their short names. Resolve collisions with an import alias.
- Compose text with Haxe single-quoted interpolation, for example `'${name}: ${count}'`.
- Keep one statement per line and use multiline blocks. Do not hand-minify source.
- Format with the standard Haxe formatter and `hxformat.json`.

## Runtime rules

- Rendering paths must not allocate once buffers have reached their working size. Avoid string concatenation, per-call closures, boxing and intermediate strings in `ByteWriter`, the interpreter and generated code.
- Keep shared runtime state immutable or protected by a lock. Guard `sys.thread` imports with `#if (target.threaded)` so non-threaded targets still compile.
- Add tests for every escaping or encoding rule, including UTF-8 boundaries and surrogate pairs.

## Verification

Run the JVM and PHP test suites before finishing a change:

```
haxe test.hxml && java -jar bin/test.jar
haxe test-php.hxml && php bin/php/index.php
```

Template fixtures under `test/fixtures` and `client/wellout.js` must also pass `prettier --check`.
