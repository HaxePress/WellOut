# Wellout

Wellout is a server-side HTML template language for Haxe. Templates are typed and sandboxed, and render straight to UTF-8 without allocating in steady state. A browser receives rendered HTML and the props of explicitly declared islands, and nothing else.

```html
<props post="ContentSummary" featured="Bool = false" />

<article class="card" :class="featured ? 'is-featured'">
  <h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
  <p :if="post.excerpt">{{ post.excerpt | truncate(160) }}</p>
</article>
```

Status: early development. The language is specified in [docs/SPEC.md](docs/SPEC.md) (draft 0.2). The front end, the op-tree backend (B) and the client runtime work; backend A, the builder IR and the requirements analyzer are next.

## What exists

- `wellout.ByteWriter`: a reusable UTF-8 buffer. It copies pre-encoded static markup, escapes and encodes text in one pass, and writes integers as digits.
- `wellout.WriterPool`: a bounded, thread-safe pool that drops writers which grew too large.
- `wellout.syntax.Parser`: reads the strict HTML subset into a document tree with declarations, directives, bindings and interpolation. It reports structural problems with positions and hints, such as unclosed elements, a misplaced `:else`, event attributes and unquoted values.
- `wellout.syntax.ExpressionParser`: parses the expression grammar, `:for` loop headers, prop declarations and type syntax into a tree with positions mapped into the template. Its diagnostics name the Wellout form for `&&`, `||`, `!` and `=`.
- `wellout.check.ExpressionChecker`: infers expression types against a host contract of view types, helpers, filters and implicit roots, and resolves every name, field, helper and filter for the backends. Paths tested by a condition are non-null inside it, null passes through filters, and unknown names and fields come with "did you mean" hints.
- `wellout.check.TemplateChecker` and `ComponentLibrary`: check whole templates against the contract and a component lookup chain: declarations, sources, directive chains, attribute contexts, component props and slots, `:attrs`, `<Head>`, islands, assets and fragments. Unused props and sources are warnings.
- `wellout.render`: backend B. `TemplateSet` checks and compiles templates once; `Renderer.render` writes a page, or one fragment, into a `ByteWriter`. URLs are checked by scheme, post forms get CSRF fields, head content and assets are collected where the layout places them. A 24-card page with a layout, loops and filters renders with 0 bytes allocated in steady state.
- `wellout.macro.ViewSchema`: builds view types from Haxe typedefs.
- `client/wellout.js`: fragment swaps, island loading and confirmations (2.1 KB gzip).
- A JVM test suite, including checks that steady-state rendering allocates 0 bytes.

## Layout

- `src/wellout/`: the framework-independent library.
- `test/`: the test suite.
- `docs/SPEC.md`: the language specification.

Framework integration lives outside this package. The first host is HaxePress (`hxwell-blog`), on the hxwell framework.

## Development

The library targets Haxe 4.3.7 and is tested on the JVM:

```
haxe test.hxml && java -jar bin/test.jar
```

To use a local checkout from another project's local haxelib repository:

```
haxelib dev wellout /path/to/wellout
```

## License

MIT. See [LICENSE](LICENSE).
