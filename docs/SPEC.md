# Wellout language specification

Status: draft 0.2, 2026-11-06. Templates use the `.well.html` extension. The short prefix `well` also names metadata (`@:well.*`), the fragment header (`Well-Fragment`) and builder preview attributes (`data-well-node`).

Wellout renders typed, sandboxed HTML templates on the server. A browser receives HTML, CSS and the props of explicitly declared islands, and nothing else. A host application supplies view types, data sources, helpers, islands and HTTP transport. HaxePress is the first host; its integration plan lives in `hxwell-blog/docs/TEMPLATE-LANGUAGE.md`.

Implementation status: the parser (§3, §4.1), the expression and template checkers (§4–§9), backend B (§13.3) with template images and the runtime (§14), the client runtime (§9.4) and the view schema macro (§6.1) exist. Backend B reads fields reflectively; the generated accessors, backend A, backend C, the IR document format, the requirements analyzer (§7.2) and the node-visit and wall-time budgets are not started.

## 1. Goals

1. **Minimal disclosure.** A response contains only rendered output and the declared props of its islands. Values used only in conditions, unused templates, template sources and private fields stay on the server.
2. **Dynamism without client state.** Templates compose components, bounded data sources, conditions and repeaters. Interactive parts use fragments, server actions and islands.
3. **Safe untrusted templates.** Templates installed at runtime, such as themes, cannot run code, query data, read private fields or emit scripts. Rendering is bounded.
4. **Zero steady-state render allocation.** Rendering writes UTF-8 into pooled buffers and allocates nothing per request after warm-up.
5. **One language.** An application's own pages, its plugins, untrusted templates and visual builders share one syntax, one intermediate representation (IR) and one validator.

Non-goals: general-purpose logic in templates, client-side page routing, executable template renderers and runtime bytecode generation.

## 2. Architecture

```
 template source (.well.html)            visual builder document
              │                                    │
              ▼                                    ▼
     parse → resolve → type-check → validate → analyze
                                                  │
                                       IR + requirements
              ┌───────────────────────────────────┼───────────────────────────────┐
              ▼                                   ▼                               ▼
  A: build-time macro → Haxe code     B: op-tree interpreter (cached)   C: B compiled to JavaScript
     application and plugin templates    templates installed at runtime    builder canvas
              └──────────────────────► pooled UTF-8 ByteWriter ◄──────────────────┘
```

| Source                                 | Trust     | Backend              | Compiled at        |
| -------------------------------------- | --------- | -------------------- | ------------------ |
| Shipped with the application           | Trusted   | A                    | Application build  |
| Shipped with a compiled plugin         | Trusted   | A                    | Plugin build       |
| Installed at runtime or built visually | Untrusted | B (C in the builder) | Install or publish |

All backends produce byte-identical output for the conformance suite (§13.4).

The host provides:

- view types and the roots each template kind receives (§6),
- source functions (§7),
- helpers such as `t`, `route`, `asset`, `can`, `old` and `error` (§4.5),
- the island registry (§9.3),
- a component library for common page parts, such as navigation, pagination, icons and extension slots,
- a link mapper for site-relative URLs (§8.2),
- the template lookup chain (§5.5),
- HTTP transport for fragments and actions (§9),
- caching of compiled templates and loaded data.

## 3. Files and document model

### 3.1 Files

- Templates and components use `*.well.html`. The double extension gives editors and formatters HTML support.
- A file may start with a `<props … />` declaration (§5.1) and a `<sources … />` declaration (§7.1), followed by markup.
- A component's name is its PascalCase file name: `components/PostCard.well.html` is `<PostCard>`.

### 3.2 Strict HTML subset

- Every non-void element is closed explicitly. Void elements (`area`, `base`, `br`, `col`, `embed`, `hr`, `img`, `input`, `link`, `meta`, `source`, `track`, `wbr`) are never closed; a trailing `/` is accepted.
- There are no implied start or end tags.
- Attribute values are quoted. Output always uses double quotes.
- Whitespace that contains a line break at the start or end of an element's content is formatting and is not written, as in JSX. Other whitespace runs that contain a line break are written as one line break, so formatters such as Prettier cannot change the output.
- HTML comments are removed from output.
- `<style>` and `<script>` are raw-text elements without interpolation. Untrusted templates may contain neither (§8.4).
- Lowercase names are HTML elements. Names starting with an uppercase letter are components, including the built-in `<Island>`, `<Asset>` and `<Assets>`. `<template>` groups siblings without producing a tag; write `<well:template>` for an HTML `<template>` element, whose content is checked and rendered like any other. `<slot>`, `<props>` and `<sources>` are reserved language elements.

### 3.3 Interpolation

- `{{ expression }}` is allowed in text and inside attribute values. Its value is always escaped for its context (§8.1), `SafeHtml` included.
- `{!! expression !!}` writes a `SafeHtml` value as HTML (§8.3). It is allowed only in element text, and only for `SafeHtml` or `SafeHtml?` values.
- Inside an element with `:verbatim`, text is output as written.
- A literal `{{` is written as `{{ '{{' }}`, and a literal `{!!` as `{{ '{!!' }}`.

### 3.4 Directives, bindings and reserved attributes

Attributes that start with `:` are directives or bindings. Directives have fixed names:

| Directive         | Value                | Meaning                                                      |
| ----------------- | -------------------- | ------------------------------------------------------------ |
| `:if`, `:else-if` | expression           | Render the element when the expression is truthy             |
| `:else`           | none                 | Render when the preceding conditions in the chain failed     |
| `:for`            | `name in expression` | Render the element once per list entry, with `loop` metadata |
| `:empty`          | none                 | Render when the preceding `:for` sibling had no entries      |
| `:let`            | name                 | Receive a scoped slot value (§5.3)                           |
| `:attrs`          | none                 | Forward caller attributes to this element (§5.2)             |
| `:verbatim`       | none                 | Disable interpolation inside the element                     |

Any other `:name="expression"` binds an attribute or a component prop to a typed value. Plain attributes are static strings that may contain interpolation.

`slot`, `fragment` and `swap` are reserved attributes. They are removed from output and can be bound with the colon form, for example `:swap="target"`.

Rules:

- `:else-if`, `:else` and `:empty` must be on the next element sibling; only whitespace may separate them.
- `:if` and `:for` cannot share an element. Use `<template :for="…">` with an inner `:if`.
- A boolean attribute bound with `:disabled="expression"` is emitted only when the value is true.
- `class` and `:class` combine. `:class` accepts a string or a list of strings; falsy entries are dropped.
- `loop` provides `index` (from 0), `number` (from 1), `first`, `last`, `length` and `parent` for nested loops.
- Event handler attributes (`on*`) are rejected everywhere.

## 4. Expressions

### 4.1 Grammar

```
expression     = conditional ;
conditional    = coalesce [ "?" expression [ ":" expression ] ] ;
coalesce       = or { "??" or } ;
or             = and { "or" and } ;
and            = not { "and" not } ;
not            = [ "not" ] comparison ;
comparison     = additive [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" ) additive ] ;
additive       = multiplicative { ( "+" | "-" ) multiplicative } ;
multiplicative = unary { ( "*" | "/" | "%" ) unary } ;
unary          = [ "-" ] filtered ;
filtered       = primary { "|" identifier [ arguments ] } ;
primary        = literal | path | call | list | record | "(" expression ")" ;
path           = identifier { "." identifier | "[" expression "]" } ;
call           = identifier arguments ;
arguments      = "(" [ argument { "," argument } ] ")" ;
argument       = [ identifier ":" ] expression ;
list           = "[" [ expression { "," expression } ] "]" ;
record         = "{" [ identifier ":" expression { "," identifier ":" expression } ] "}" ;
literal        = string | number | "true" | "false" | "null" ;
```

- `condition ? value` without `: other` yields nothing when the condition fails. It is meant for class lists and optional text.
- `+`, `-`, `*`, `/` and `%` operate on numbers. Text is composed with interpolation.
- `in` tests membership in a list.
- Comparisons do not chain: `a < b < c` is an error. Combine comparisons with `and`.
- Positional arguments come before named arguments, and record keys are unique.
- Strings use single or double quotes with the escapes `\\`, `\'`, `\"`, `\n`, `\t`, `\r` and `\uXXXX`. Generated templates use `\u0022` for a double quote inside an attribute. A line break inside a string, with the spaces and tabs around it, reads as a single space, so formatters can wrap long text such as translation keys; write `\n` for a line break. Integers fit in 32 bits; larger numbers are written as decimals.
- `&&`, `||`, `!`, `===` and a single `=` are rejected with a hint naming the Wellout form.

### 4.2 Names

- A path starts at a prop, a source, a loop variable, `loop` or an implicit root (§5.6).
- Calls reach only registered helpers (§4.5).
- There are no method calls, assignments, reflective lookups, global names or user-defined functions.

### 4.3 Types

Types are `String`, `Int`, `Float`, `Bool`, `Date`, `Url`, `SafeHtml`, `Fragment`, `List<T>`, `Map<String, T>`, nullable `T?` and the host's view types (§6). In declarations they are written as:

```
type = identifier [ "<" type { "," type } ">" ] [ "?" ] ;
```

The compiler infers expression types and reports:

- unknown fields, with suggestions such as "did you mean `title`?",
- type mismatches in props, comparisons and filter arguments,
- nullable values passed to non-null props,
- unused props and sources (warnings).

A path tested by `:if` or `:else-if`, by the left operand of `and`, by the condition of `? :` or by `path != null` is non-null in the part it guards, and so is every prefix of it. Arithmetic, ordering comparisons and non-null parameters reject nullable values; `??` or `default` supplies a value. Lists are indexed with `Int`, maps with `String`, and an index read is nullable because the entry may be missing. A computed map key makes the analyzer require every public entry of that map (§7.2).

### 4.4 Truthiness and null

- Falsy values are `false`, `null`, `""`, `0`, `0.0` and empty lists and maps. Everything else is truthy.
- Paths are null-safe: a null segment yields `null`.
- Filters are null-safe too: a filter whose input is not nullable is skipped for a null input and yields `null`, so `post.excerpt | truncate(160)` has the type `String?`. `default(value)` substitutes a value.
- Printing `null` outputs nothing.

### 4.5 Filters and helpers

A filter is a Haxe function registered with a typed signature and two implementations:

- a **writer** that writes its result straight into the output buffer,
- an optional **value** form for results that are compared or passed as arguments.

Output positions always use the writer, so formatting does not allocate.

Built-in filters: `date(style)`, `number(style)`, `truncate(length)`, `lower`, `upper`, `default(value)`, `color` (validated `#rrggbb`) and `length` (validated CSS length).

Helpers are registered by the host. The reference set:

- `t(key, name: value, …)`: translation (§10),
- `route(name, …)`: named route URL,
- `asset(path)`: asset URL,
- `can(capability)`: capability check for presentation,
- `old(field)` and `error(field)`: form state (§9.2).

Routes used by templates must be named.

## 5. Components, slots and layouts

### 5.1 Props

```html
<props post="ContentSummary" featured="Bool = false" heading="String?" />
```

- Each attribute declares one prop: the attribute name is the prop name, and the value is `type [ "=" expression ]` with the type syntax of §4.3. Props without defaults are required.
- Declarations are attributes so that HTML formatters keep them intact; a long declaration is formatted one attribute per line.
- Page templates declare the props their route provides; components declare the props their callers pass.

### 5.2 Using components

```html
<PostCard :post="post" :featured="loop.first" />

<Card title="About">
  <p>Default slot content</p>
  <template slot="footer"><a href="/about">More</a></template>
</Card>
```

- Static attributes pass `String` props; `:name` passes typed values.
- Undeclared attributes are errors, unless the component marks one element with `:attrs`. That element receives the caller's `class` (appended), `id`, `aria-*` and `data-*` attributes.

### 5.3 Slots

- `<slot />` is the default outlet; `<slot name="footer">fallback</slot>` is a named outlet with fallback content.
- Callers fill named slots with `<template slot="footer">…</template>`.
- A scoped slot exposes values: the component writes `<slot name="row" :row="row" />` and the caller writes `<template slot="row" :let="row">…</template>`.

### 5.4 Layouts

Layouts are components with slots. There is no separate inheritance syntax.

### 5.5 Resolution

The host defines the lookup chain for component names, for example a theme, its parent theme, namespaced plugin components (`<newsletter:Signup>`) and the application's own components. A template earlier in the chain overrides a later one with the same name.

### 5.6 Implicit roots

The host declares a fixed set of implicit, read-only, typed roots, such as `site`, `locale`, `request`, `csrf` and `nonce`. Version 1 has no user-defined context.

### 5.7 Head content

Pages contribute to the document head with the built-in `<well:head>` component:

```html
<well:head>
  <title>{{ item.seo_title ?? item.title }} — {{ site.site_name }}</title>
  <meta name="description" content="{{ item.seo_description ?? item.excerpt }}" />
  <link rel="canonical" href="{{ item.url }}" />
</well:head>
```

- The prefix keeps HTML formatters from lower-casing the component into a `<head>` element. `<Head>` is rejected with a hint.
- `<well:head>` may contain only `<title>`, `<meta>` and `<link>`.
- A layout places `<HeadOutlet />` inside `<head>`.
- `<well:head>` subtrees are hoisted at compile time and rendered at the outlet, before the body. They may read props and sources and loop over them, but not read loop variables or slot values from outside, so the head never waits for the body.
- When several components contribute a `<title>`, the one closest to the page template wins.

## 6. Host data contracts

### 6.1 View types

Templates read typed view records that the host declares in Haxe. A schema macro processes each declaration:

```haxe
@:well.view
typedef ContentSummary = {
    var title:String;
    @:well.columns("slug", "content_type") var url:Url;
    var excerpt:String;
    var image:Null<Url>;
    var image_alt:String;
    @:well.columns("reading_minutes") var readMinutes:Int;
    var published_at:Null<Date>;
    @:well.requires("team.view") var author_name:String;
}
```

From each view type, the macro generates:

1. the type information templates are checked against,
2. a final class with direct fields, used at runtime instead of anonymous structures,
3. typed accessor classes for backend B,
4. projection metadata: the storage columns each field needs.

### 6.2 Field rules

- Templates can read only fields declared on a view type. Loaders build records by allowlist projection; they never copy model objects.
- `@:well.columns` lists the columns a derived field needs. A plain field maps to the column of the same name.
- `@:well.requires(capability)` fields are loaded only when the viewer holds that capability. Reading one outside a matching `can()` guard is a compile warning; the loader enforces the rule either way.
- `@:well.private` fields are invisible to templates.

### 6.3 Contexts

The host defines which roots and view types each template kind receives, and versions that contract. Additions within a major version are backward compatible.

## 7. Data sources and requirements

### 7.1 Sources

```html
<sources
  travel="entries(collection: 'entry', category: 'travel', limit: 3)"
  more="related(item, limit: 4)"
  total="count(collection: 'entry')"
/>
```

- Each attribute declares one named source. Source functions are registered by the host, which implements and bounds them.
- Arguments are literals or context paths such as `item.category`. Every argument is part of the source's cache key.
- Counts are separate sources with their own cache keys, never derived from result rows.
- A source name is a typed value in the template or component that declares it, for example `List<ContentSummary>`.

### 7.2 Requirements

For each template, component and fragment, the analyzer computes:

- the field paths used per prop and source,
- the columns those fields need, including `@:well.columns` dependencies,
- the sources to resolve,
- translation keys,
- islands, with their assets and translation keys,
- the capabilities consulted.

A page's requirements are the union over its template, layout and rendered components. They are computed once per compiled version.

### 7.3 Resolution

Before rendering, the host's loader resolves props and sources from the requirements:

- it selects only the required columns,
- applies limits and de-duplicates identical sources,
- caches results under keys that include every filter, cursor, page size and identifier.

Rendering itself performs no I/O.

## 8. Escaping and output safety

### 8.1 Output contexts

| Context                                                                  | Treatment                                            |
| ------------------------------------------------------------------------ | ---------------------------------------------------- |
| Text                                                                     | `&`, `<`, `>`, `"` and `'` are encoded               |
| Attribute value                                                          | Same encoding; always double-quoted                  |
| URL attributes (`href`, `src`, `action`, `formaction`, `poster`, `cite`) | Scheme allowlist, then attribute encoding            |
| `srcset`                                                                 | Each candidate URL is validated                      |
| `style` attribute                                                        | Only typed CSS filters (`color`, `length`, `number`) |
| `<style>`, `<script>`                                                    | No interpolation                                     |
| Island props                                                             | JSON with `<`, `>`, `&`, U+2028 and U+2029 escaped   |

### 8.2 URLs

Allowed URLs:

- relative paths (a `/` not followed by another `/`),
- fragments (`#…`),
- `http:`, `https:`, `mailto:` and `tel:` URLs.

Other values are replaced with an empty value. Hosts may restrict image URLs further, for example to managed media.

Site-relative URLs pass through the host's link mapper before they are written. A host can use it to keep links inside a preview, as HaxePress does for theme previews, so templates always write plain paths such as `/content`.

### 8.3 SafeHtml

`SafeHtml` values come only from trusted host code, such as a content renderer or an HTML sanitizer. Templates cannot create `SafeHtml`, and there is no `raw` filter.

Every output is escaped by default. HTML is written only where a template asks for it with `{!! … !!}`, and only for a `SafeHtml` value:

| Template               | Value      | Output                                        |
| ---------------------- | ---------- | --------------------------------------------- |
| `{{ value }}`          | any        | Escaped text                                  |
| `{{ html }}`           | `SafeHtml` | Escaped text, with the warning `escaped-html` |
| `{!! html !!}`         | `SafeHtml` | HTML, as the host produced it                 |
| `{!! value !!}`        | other      | Error `raw-output-type`                       |
| `title="{!! html !!}"` | any        | Error `raw-in-attribute`                      |

So a template cannot turn text into markup: raw output needs both the marker in the template and a value the host vouched for. Hosts should cache large `SafeHtml` values as UTF-8 bytes (§14.3).

### 8.4 Element policy for untrusted templates

The host supplies the tag allowlist. The reference policy:

- **Allowed attributes:** `id`, `class`, `title`, `lang`, `dir`, `role`, `aria-*`, `data-*` and element-specific attributes.
- **Interactive HTML without JavaScript:** `<details>`, `<summary>`, `<dialog>` and the `popover`, `popovertarget` and `popovertargetaction` attributes are allowed. They cover menus, disclosures and simple overlays without an island.
- **Inline SVG:** `<svg>`, `<g>`, `<path>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<title>` and `<desc>`, with presentation attributes such as `viewBox`, `d`, `fill`, `stroke`, `stroke-width` and `transform`. `<foreignObject>`, `<use>` with external references and SVG event attributes are rejected.
- **Rejected:** `on*` attributes, untyped `style` values and `srcdoc`, plus the `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>` and `<base>` elements.

### 8.5 Forms

- `<form method="post">` receives a CSRF field automatically.
- `put`, `patch` and `delete` methods become POST with method spoofing.
- Untrusted templates may post only to routes the host registers as public actions.

## 9. Dynamic behaviour

### 9.1 Fragments

```html
<section fragment="results">…</section>
```

A request with the `Well-Fragment: results` header, or `?_fragment=results`, renders only that element. A fragment's requirements are computed separately, so sources it does not use are not loaded. Fragment responses vary on the fragment name and are cached like pages.

### 9.2 Actions and swapped links

```html
<div fragment="signup">
  <form method="post" action="{{ route('newsletter.subscribe') }}" swap="signup">
    <input name="email" type="email" value="{{ old('email') }}" />
    <p :if="error('email')" class="error">{{ error('email') }}</p>
    <button>{{ t('Subscribe') }}</button>
  </form>
</div>
```

- **Without JavaScript,** the form posts normally. The handler validates and redirects (post/redirect/get). Errors and old input are kept in the session for the next request.
- **With the runtime script,** the form is sent with `fetch`, the response is the re-rendered `swap` fragment, and it replaces the fragment in place. No component state is sent to the browser.
- **Links** can use `swap` too: `<a href="?cursor=…" swap="results">` fetches only that fragment and updates the address.
- **Handlers** are ordinary host routes; their middleware, CSRF protection and authorization apply.

### 9.3 Islands

```html
<Island name="media-uploader" :props="{ maxBytes: limits.maxBytes }" load="interaction">
  <p>{{ t('Upload an image from your device.') }}</p>
</Island>
```

- An island is a client module registered with the host, together with a typed props schema and the translation keys it uses.
- Props are type-checked. Private and capability-tagged fields cannot be passed.
- The server renders the children as fallback content, followed by the props in a `<script type="application/json">` element that carries the response nonce.
- `load` is `eager`, `idle`, `visible` or `interaction`. Island code loads only on pages that contain the island.
- Island translation keys are the only catalogue entries sent to the browser.
- Output: `<well-island data-name="…" data-load="…" data-module="…">fallback<script type="application/json" data-well-props nonce="…">{"props":…,"messages":{…}}</script></well-island>`. The module exports `mount(element, props, messages)`.

### 9.4 Runtime script

One small module provides fragment swapping, action submission, island loading and focus and scroll restoration. The target size is under 5 KB gzip. Pages without swaps or islands load no JavaScript.

- The renderer writes fragments with `data-well-fragment="name"` and swap targets with `data-well-swap="name"`, and adds the runtime script at `<Assets />` when a page swaps or has islands.
- A swap request carries `Well-Fragment: name`; the host answers with the fragment and the same response header. Any other response is followed as a normal navigation.
- A form swap sends its fields as the browser would: in the query for `get`, URL-encoded for `post`, and as multipart only when the form has `enctype="multipart/form-data"`.
- `data-well-confirm="message"` on a form, button or link asks before submitting or following it. A submit button, including one linked to its form with `form="id"`, is asked once, when its form submits.
- `data-well-autosubmit` on a form field submits its form when the value changes. Its value may name the id of a submit button of that form, which is then the submitter (its name, value and `formaction` apply).
- With `data-well-confirm`, a page may provide `<dialog id="well-confirm">` with an element marked `data-well-confirm-message` and buttons marked `data-well-answer="confirm"` and `data-well-answer="cancel"`; the prompt then uses the page's own design.
- `data-well-open="id"` opens the `<dialog>` with that id as a modal; `data-well-close` closes the dialog it is in; a dialog with `data-well-dismiss` closes when its backdrop is clicked.
- `data-well-reveal="id"` toggles a password input between hidden and shown text, updating `aria-pressed`, the label from `data-well-show-label` and `data-well-hide-label`, and children marked `data-well-pressed="true|false"`.
- `data-well-busy="label"` on a submit button shows that label and disables the button while the form submits.
- `data-well-toggle="id"` shows or hides the element with that id (its `hidden` attribute), updating `aria-expanded` and the label from `data-well-show-label` and `data-well-hide-label`.
- `data-well-hotkey="k"` clicks the element when Ctrl or Cmd and that key are pressed.
- Any static `data-well-*` attribute makes the page load the runtime.
- Post forms receive a hidden `_token` field; `put`, `patch` and `delete` forms also receive `_method`.
- The reference implementation is `client/wellout.js` (2.1 KB gzip).

### 9.5 Navigation

Same-origin links may use speculation rules for prefetch or prerender, and cross-document view transitions, as progressive enhancements. There is no client-side routing.

### 9.6 Live regions

Server-pushed fragment updates over WebSockets are planned for version 2.

## 10. Internationalization

- `t(key, name: value, …)` supports ICU MessageFormat plural and select. The host supplies the catalogues.
- Keys are extracted at compile time. Publishing an untrusted template reports keys that are missing for enabled locales.
- Rendering translates on the server; only island keys reach the browser.
- `lang` and `dir` come from the locale. Date and number writers are locale-aware.

## 11. Assets and content security policy

- `<Asset css="card.css" />` and `<Asset js="…" />` declare assets inside templates and components. The layout's `<Assets />` emits each asset once, fingerprinted, in order of first use.
- Every response gets a CSP nonce. Only system output carries it: the runtime script and island props. Untrusted templates cannot emit scripts.
- Builder styles compile to a versioned stylesheet. Customizer variables are emitted in a style block with the nonce, so pages need no `unsafe-inline`.

Starting policy: `default-src 'self'; script-src 'self' 'nonce-…'; style-src 'self' 'nonce-…'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'`.

## 12. Security model and budgets

### 12.1 Trust

- Templates shipped with the application or a compiled plugin are trusted and compiled with backend A.
- Templates installed at runtime are untrusted input. They are parsed, validated and interpreted, and can reach only their own context.

### 12.2 Compile-time limits

Reference limits for untrusted templates, which hosts may tighten:

- 1 MB per document,
- 2048 nodes,
- 16 nesting levels,
- 20,000 expanded elements per template,
- bounded catalogues of templates, components and sources.

### 12.3 Render budgets

| Budget          | Default                           |
| --------------- | --------------------------------- |
| Output size     | 2 MB                              |
| Node visits     | 200,000                           |
| Component depth | 16                                |
| Wall time       | 50 ms, checked every 1,024 visits |

When a budget is exceeded, the render stops and the host's fallback template renders instead. The event is logged with the template and the budget.

## 13. Compilation

### 13.1 Front end

The front end runs in this order:

1. parse,
2. resolve components,
3. type-check against view types,
4. validate policy and limits,
5. analyze requirements,
6. lower to IR.

Diagnostics carry a code, a message, the file, line and column, a source excerpt and suggestions. The structured form is also suitable for AI design tools.

### 13.2 IR

The IR is Wellout's document format. Visual builders may store it directly. Every language construct maps to a node or a node property:

| Language                      | IR                                                                     |
| ----------------------------- | ---------------------------------------------------------------------- |
| Elements, attributes, `{{ }}` | Element nodes with static and bound attributes; text and binding nodes |
| `:if`, `:else-if`, `:else`    | Node condition chain                                                   |
| `:for`, `:empty`              | Repeat node with an empty branch                                       |
| Components and slots          | Component node with slot children                                      |
| `fragment`, `<Island>`        | Fragment and island nodes                                              |
| `<sources … />`               | Document sources                                                       |

### 13.3 Backends

- **A. Build-time macro.** Generates one Haxe function per template that writes into a `ByteWriter`. Static runs become `static final` pre-encoded `Bytes`. Fields are read with typed access, so the Haxe compiler checks templates against the real types.
- **B. Op tree.** The IR is lowered into immutable operation objects: chunk, text, number, condition, repeat, component, slot, fragment and island. Field reads use the generated typed accessor classes, without reflection or boxing. The host caches compiled trees by template version and compiler version. The reference implementation (`wellout.render`) compiles checked templates directly, keeps values and loop counters in pooled frames, and allocates nothing per render in steady state; it reads fields reflectively until the accessors exist.

  Hosts that start for each request, such as PHP, keep compiled trees as images (`TemplateImage`). An image holds only strings, numbers, booleans, null and arrays, so a host stores it as data, for example as a PHP array literal that opcache keeps in shared memory, never as code generated from a template. A `TemplateSet` with a `TemplateStore` restores a template from its image before it parses, checks and compiles it, and saves the image of each template it compiles. `PhpTemplateStore` is the store for PHP: one file per template under a folder named by the set version and the image format, written with `var_export` and renamed into place. Restoring rebuilds the same op tree and resolves helpers, filters, sources and components by name, so output, escaping, URL checks and budgets are those of the compiled tree. Images carry a format version; the host keys stored images by their sources and drops images it cannot restore.

- **C. JavaScript.** Backend B compiled with the Haxe JavaScript target. A builder canvas renders with it and adds `data-well-node` attributes in preview output only, to map rendered elements back to editable nodes.

### 13.4 Conformance

A shared suite renders the same templates and fixtures through backends A, B and C and requires byte-identical output, including escaping, UTF-8 and error cases.

## 14. Runtime

### 14.1 ByteWriter

`wellout.ByteWriter` is implemented:

- `chunk(bytes)` copies pre-encoded static markup.
- `text(value)` escapes and UTF-8 encodes in one pass, straight into the buffer. Supplementary characters are encoded from surrogate pairs or code points; lone surrogates become U+FFFD.
- `trusted(value)` encodes text that a trusted producer already made safe.
- `int(value)` writes decimal digits without creating a string.
- Text is processed in blocks of 4,096 characters, so capacity is never over-reserved by more than one block.

Filters and derived fields write directly into the writer as well.

On PHP, whose strings index code points, the writer keeps a native string, appends in place and escapes with `htmlspecialchars` (`ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML401`, the same table); JSON strings use `strtr` with the JSON writer's table. Invalid UTF-8 becomes U+FFFD. The test suite runs on PHP with the same expected output (`test-php.hxml`).

### 14.2 Writer pool

`wellout.WriterPool` is implemented:

- Writers come from a bounded, thread-safe pool and are reset when acquired.
- A writer returns to the pool only after the host reports that its bytes are no longer referenced, for example after the HTTP driver has written them.
- Writers whose capacity grew beyond `maxCapacity` (1 MB by default) are dropped instead of returned.

### 14.3 Pre-encoded content

Large `SafeHtml` values and rarely changing shared regions should be cached as UTF-8 bytes keyed by their revision, and written with a single copy.

### 14.4 Targets

| Measure                                | Target                                            |
| -------------------------------------- | ------------------------------------------------- |
| Reference list (24 cards), backend A   | ≤ 11 µs and 0 bytes allocated per render          |
| Reference list, backend B              | ≤ 14 µs and 0 bytes allocated per render          |
| `ByteWriter` steady state (test suite) | 0 bytes allocated (measured: 0 in 10,000 renders) |

## 15. Open questions

1. Attribute order: Prettier formats `.well.html` stably at a print width of 100 (checked on the test fixtures), but it keeps the author's attribute order, so placing control directives first needs a lint rule.
2. Scoped slots in version 1 or later.
3. Budget defaults after profiling real templates.
4. Backend B performance on the PHP target. Images and the native writer remove compilation and quadratic encoding from each request; restoring an image still builds its op tree per request.
5. Whether islands from untrusted templates may be any ES module or must use a constrained runtime.
6. Name of the hxwell adapter package.

## Appendix A: Examples

### A.1 Component

`components/PostCard.well.html`:

```html
<props post="ContentSummary" featured="Bool = false" />

<article class="card" :class="featured ? 'is-featured'">
  <img :if="post.image" src="{{ post.image }}" alt="{{ post.image_alt }}" />
  <h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
  <p :if="post.excerpt">{{ post.excerpt | truncate(160) }}</p>
  <time :if="post.published_at" datetime="{{ post.published_at | date('iso') }}">
    {{ post.published_at | date('long') }}
  </time>
</article>
```

### A.2 Page template

`templates/Home.well.html`:

```html
<props items="List<ContentSummary>" featured="ContentSummary?" />
<sources travel="entries(collection: 'entry', category: 'travel', limit: 3)" />

<Layout :title="site.site_name">
  <PostCard :if="featured" :post="featured" :featured="true" />
  <section fragment="list">
    <PostCard :for="post in items" :post="post" />
    <p :empty>{{ t('Nothing published yet') }}</p>
  </section>
  <aside>
    <h2>{{ t('Travel') }}</h2>
    <PostCard :for="post in travel" :post="post" />
  </aside>
  <Island name="newsletter:signup" :props="{ list: 'main' }" load="visible">
    <a href="{{ route('newsletter.page') }}">{{ t('Subscribe') }}</a>
  </Island>
</Layout>
```

From this template and `PostCard`, the compiler derives:

- **Columns:** `title`, `slug`, `content_type`, `excerpt`, `image`, `image_alt` and `published_at`. `reading_minutes` is not selected because no template reads `readMinutes`.
- **Sources:** one query for `travel`, cached under `(collection, category, limit)`.
- **Fragments:** a `?_fragment=list` request loads only `items`; `travel` is not resolved.
- **Translations:** three keys, translated on the server.
- **Browser payload:** HTML, the island props `{"list":"main"}`, the island module and the runtime script.

### A.3 Application page

```html
<props tags="List<TagRow>" page="CursorPage" />

<AdminLayout :title="t('Tags')">
  <div fragment="tag-form">
    <form method="post" action="{{ route('admin.tags.save') }}" swap="tag-form">
      <label>
        {{ t('Name') }}
        <input name="name" value="{{ old('name') }}" required />
      </label>
      <p :if="error('name')" class="field-error">{{ error('name') }}</p>
      <button :disabled="not can('tags.manage')">{{ t('Save') }}</button>
    </form>
  </div>
  <table>
    <tbody fragment="tag-rows">
      <tr :for="tag in tags">
        <td>{{ tag.name }}</td>
        <td>{{ tag.count | number }}</td>
      </tr>
      <tr :empty>
        <td colspan="2">{{ t('No tags yet') }}</td>
      </tr>
    </tbody>
  </table>
  <Pagination :page="page" target="tag-rows" />
</AdminLayout>
```

`Pagination` declares `target="Fragment?"` and renders its links with `:swap="target"`.

## Appendix B: Comparison

| Concern           | mtt (`haxe.Template`)                                    | Laravel Blade                               | Wellout                                          |
| ----------------- | -------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------ |
| Default escaping  | None                                                     | `htmlspecialchars` for every context        | By output context (§8.1)                         |
| Raw output        | Always                                                   | `{!! !!}` for any value                     | `{!! !!}`, only for `SafeHtml` from trusted code |
| Sandbox           | Reflection and property getters                          | None: templates are PHP                     | No code, I/O or reflection                       |
| Data contract     | None                                                     | Untyped `@props`; implicit shared data      | Typed props and view records                     |
| Data loading      | Host prepares everything                                 | Templates may lazy-load relations           | Declared, bounded sources; analyzed projections  |
| HTML awareness    | None                                                     | None                                        | Strict parse, tag and attribute policy           |
| Composition       | Macros only                                              | Inheritance plus components                 | Components, slots, layouts as components         |
| Dynamic behaviour | None                                                     | `@fragment`; Livewire sends state snapshots | Fragments, actions, typed islands                |
| JVM behaviour     | `::if::` on strings throws; anonymous-object macros fail | Not applicable                              | Backends A and B, conformance-tested             |

## Appendix C: Render benchmark

Measured on 2026-11-06 on macOS with Java 25 and Haxe 4.3.7. The reference template renders 24 cards: 6,416 bytes of UTF-8 output, with entities and non-ASCII text. Each variant ran 20,000 renders after warm-up, measured with `ThreadMXBean.getCurrentThreadAllocatedBytes()`. All outputs are byte-identical.

| Variant                                      | µs per render | Bytes allocated per render |
| -------------------------------------------- | ------------- | -------------------------- |
| mtt cached, `$$e` escaping, to `String`      | 57.0          | 149,280                    |
| Generated code to `String`                   | 10.8          | 51,936                     |
| Generated code to `String`, then UTF-8 bytes | 18.0          | 77,552                     |
| Generated code to pooled `ByteWriter`        | 10.7          | 0                          |
| Op tree to pooled `ByteWriter`               | 13.8          | 0                          |
| Op tree to a new `ByteWriter` per render     | 13.7          | 8,256                      |
