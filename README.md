# Wellout

Wellout is a server-side HTML template language for Haxe. Templates are typed and sandboxed, and render straight to UTF-8 without allocating in steady state. A browser receives rendered HTML and the props of explicitly declared islands, and nothing else.

```html
<props post="ContentSummary" featured="Bool = false" />

<article class="card" :class="featured ? 'is-featured'">
  <h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
  <p :if="post.excerpt">{{ post.excerpt | truncate(160) }}</p>
</article>
```

Status: early development. The language is specified in [docs/SPEC.md](docs/SPEC.md) (draft 0.2). The runtime output layer and the template parser are implemented; the expression parser, type checker and backends are next.

## What exists

- `wellout.ByteWriter`: a reusable UTF-8 buffer. It copies pre-encoded static markup, escapes and encodes text in one pass, and writes integers as digits.
- `wellout.WriterPool`: a bounded, thread-safe pool that drops writers which grew too large.
- `wellout.syntax.Parser`: reads the strict HTML subset into a document tree with declarations, directives, bindings and interpolation. It reports structural problems with positions and hints, such as unclosed elements, a misplaced `:else`, event attributes and unquoted values.
- A JVM test suite, including a check that steady-state rendering allocates 0 bytes.

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
