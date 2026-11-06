import wellout.ByteWriter;
import wellout.Result;
import wellout.check.CheckedTemplate.AssetKind;
import wellout.check.ComponentLibrary;
import wellout.check.HostContract;
import wellout.check.Types;
import wellout.render.CompiledTemplate;
import wellout.render.RenderHost;
import wellout.render.Renderer;
import wellout.render.Runtime;
import wellout.render.TemplateSet;
import wellout.syntax.Diagnostic;
#if jvm
import haxe.Int64;
import JvmAllocation.AllocationCounter;
import JvmAllocation.ManagementFactory;
#end

using StringTools;

class TestHost implements RenderHost {
    public var base = "";

    final site:Dynamic = {site_name: "Field & Notes", tagline: null};

    public function new() {}

    public function root(name:String):Dynamic {
        return name == "site" ? site : null;
    }

    public function linkBase():String {
        return base;
    }

    public function csrfToken():String {
        return "tok\"en";
    }

    public function nonce():String {
        return "n0nce";
    }

    public function assetUrl(kind:AssetKind, path:String):String {
        return '/assets/${path}';
    }

    public function islandModule(name:String):String {
        return '/islands/${name}.js';
    }

    public function translate(key:String):String {
        return key == "Upload" ? "Yükle" : key;
    }

    public function runtimeScript():String {
        return "/wellout.js";
    }
}

class TemplateTest {
    static var check:(Bool, String) -> Void;
    static var contract:HostContract;
    static var runtime:Runtime;
    static var host:TestHost;
    static var sourceCalls = 0;

    public static function run(assert:(Bool, String) -> Void):Void {
        check = assert;
        contract = buildContract();
        runtime = buildRuntime();
        host = new TestHost();
        rendersTextAndEscaping();
        rendersAttributes();
        checksUrls();
        rendersBranchesAndLoops();
        rendersComponentsAndSlots();
        forwardsAttributes();
        collectsHeadContent();
        rendersFragments();
        rendersIslandsAndAssets();
        rendersForms();
        loadsSources();
        reportsTemplateProblems();
        #if jvm
        rendersPagesWithoutAllocating();
        #end
    }

    static function buildContract():HostContract {
        var contract = new HostContract();
        contract.addView(new RecordType("Post", [
            new FieldInfo("title", TString),
            new FieldInfo("url", TUrl),
            new FieldInfo("excerpt", TNullable(TString)),
            new FieldInfo("image", TNullable(TUrl)),
            new FieldInfo("minutes", TInt),
            new FieldInfo("tags", TList(TString))
        ]));
        contract.addView(new RecordType("Site", [
            new FieldInfo("site_name", TString),
            new FieldInfo("tagline", TNullable(TString))
        ]));
        contract.addRoot("site", TView("Site"));
        contract.addHelper(new HelperSignature("t", [new Parameter("key", TString)], TString,
            true));
        contract.addHelper(new HelperSignature("can", [new Parameter("capability", TString)],
            TBool));
        contract.addSource(new SourceSignature("latest", [new Parameter("limit", TInt)],
            TList(TView("Post"))));
        contract.addIsland(new IslandSignature("uploader",
            TRecord([new FieldInfo("max", TInt), new FieldInfo("label", TString)]), ["Upload"]));
        return contract;
    }

    static function buildRuntime():Runtime {
        var runtime = new Runtime();
        runtime.addHelper("t", (arguments, _) -> {
            var key = arguments.string(0);
            var count = arguments.named("count");
            return count == null ? key : StringTools.replace(key, "{count}", Std.string(count));
        });
        runtime.addHelper("can", (arguments, _) -> arguments.string(0) == "edit");
        runtime.addSource("latest", (arguments, _) -> {
            sourceCalls++;
            return [for (index in 0...arguments.int(0)) post('Latest ${index}')];
        });
        return runtime;
    }

    static function post(title:String, ?excerpt:String, ?image:String):Dynamic {
        return {
            title: title,
            url: '/content/${title.toLowerCase().replace(" ", "-")}',
            excerpt: excerpt,
            image: image,
            minutes: 3,
            tags: ["a", "b"]
        };
    }

    static function set(templates:Map<String, String>):TemplateSet {
        var library = new ComponentLibrary(contract);
        for (name => source in templates) {
            library.add(name, source);
        }
        return new TemplateSet(contract, runtime, library);
    }

    static function compiled(templates:Map<String, String>, name:String):Null<CompiledTemplate> {
        var result = set(templates).template(name);
        var errors = result.diagnostics.filter(diagnostic -> diagnostic.isError());
        if (result.value == null || errors.length > 0) {
            var printed = [for (error in errors) '${error.code}@${error.position}: ${error.message}'];
            check(false, '${name} compiles (got ${printed.join("; ")})');
            return null;
        }
        return result.value;
    }

    static function render(templates:Map<String, String>, name:String, props:Dynamic,
            ?fragment:String):String {
        var template = compiled(templates, name);
        if (template == null) {
            return "";
        }
        var writer = new ByteWriter(256);
        var found = Renderer.render(template, props, host, writer, {fragment: fragment});
        return found ? writer.toString() : "<missing>";
    }

    static function expect(templates:Map<String, String>, name:String, props:Dynamic,
            expected:String, label:String, ?fragment:String):Void {
        var output = render(templates, name, props, fragment);
        check(output == expected, '${label}: expected\n  ${expected}\ngot\n  ${output}');
    }

    static function diagnosticsOf(templates:Map<String, String>, name:String):Array<Diagnostic> {
        var library = new ComponentLibrary(contract);
        for (template => source in templates) {
            library.add(template, source);
        }
        var result = library.check(name);
        return result == null ? [] : result.diagnostics;
    }

    static function expectProblem(templates:Map<String, String>, name:String, code:String,
            line:Int, column:Int, label:String):Void {
        var diagnostics = diagnosticsOf(templates, name);
        var found = diagnostics.filter(diagnostic -> diagnostic.code == code);
        var summary = [for (diagnostic in diagnostics) '${diagnostic.code}@${diagnostic.position}'];
        check(found.length > 0, '${label}: expected ${code} (got ${summary.join(", ")})');
        if (found.length > 0) {
            check(found[0].position.line == line && found[0].position.column == column,
                '${label}: expected ${code} at ${line}:${column}, got ${found[0].position}');
        }
    }

    static function rendersTextAndEscaping():Void {
        var page = [
            "Page" =>
            '<props post="Post" />\n<article>\n  <h2>{{ post.title }}</h2>\n  <p>{{ post.excerpt }}</p>\n</article>\n'
        ];
        expect(page, "Page", {post: post("Tom & <Jerry>", null)},
            '<article>\n<h2>Tom &amp; &lt;Jerry&gt;</h2>\n<p></p>\n</article>',
            "text is escaped and null prints nothing");
        var literal = ["Page" => '<p>Fish &amp; chips — {{ \'{{\' }} &lt;3</p>'];
        expect(literal, "Page", {}, '<p>Fish &amp; chips — {{ &lt;3</p>',
            "template text is markup and written as it is");
        var site = [
            "Page" => '<h1>{{ site.site_name }}</h1><p>{{ site.tagline ?? t(\'No tagline\') }}</p>'
        ];
        expect(site, "Page", {}, '<h1>Field &amp; Notes</h1><p>No tagline</p>',
            "roots and helpers");
        var numbers = [
            "Page" =>
            '<props count="Int" ratio="Float" /><p>{{ count + 1 }} {{ count / 4 }} {{ ratio * 2 }} {{ t(\'{count} items\', count: count) }}</p>'
        ];
        expect(numbers, "Page", {count: 5, ratio: 1.25}, '<p>6 1.25 2.5 5 items</p>', "numbers");
        var filters = [
            "Page" =>
            '<props post="Post" /><p>{{ post.title | truncate(9) }}|{{ post.excerpt | truncate(3) }}|{{ post.excerpt | default(\'none\') | upper }}</p>'
        ];
        expect(filters, "Page", {post: post("A long title here", null)},
            '<p>A long ti…||NONE</p>', "filters write and skip null");
        var safe = ["Page" => '<props body="SafeHtml" /><div>{{ body }}</div>'];
        expect(safe, "Page", {body: "<b>bold</b>"}, '<div><b>bold</b></div>',
            "SafeHtml is written unescaped");
    }

    static function rendersAttributes():Void {
        var page = [
            "Page" =>
            '<props post="Post" featured="Bool" busy="Bool" /><a class="card" :class="[featured ? \'is-featured\', busy ? \'is-busy\']" href="{{ post.url }}" title="{{ post.excerpt }}" :data-title="post.excerpt" :disabled="busy" :aria-busy="busy">x</a>'
        ];
        expect(page, "Page", {post: post("Hello", "Say \"hi\""), featured: true, busy: false},
            '<a class="card is-featured" href="/content/hello" title="Say &quot;hi&quot;" data-title="Say &quot;hi&quot;" aria-busy="false">x</a>',
            "class list, URL, interpolated and bound attributes");
        expect(page, "Page", {post: post("Hello", null), featured: false, busy: true},
            '<a class="card is-busy" href="/content/hello" title="" disabled aria-busy="true">x</a>',
            "null bound attributes are omitted, boolean attributes follow truthiness");
        var empty = ["Page" => '<props on="Bool" /><span :class="on ? \'x\'">y</span>'];
        expect(empty, "Page", {on: false}, '<span>y</span>', "an empty class list is omitted");
        var input = ["Page" => '<input name="q" required value="{{ t(\'a&b\') }}" />'];
        expect(input, "Page", {}, '<input name="q" required value="a&amp;b">',
            "void elements and present attributes");
        var style = [
            "Page" =>
            '<props color="String" /><div style="--accent: {{ color | color }}; width: {{ 3 }}px">x</div>'
        ];
        expect(style, "Page", {color: "#2457a6"},
            '<div style="--accent: #2457a6; width: 3px">x</div>', "typed style values");
        expect(style, "Page", {color: "red;background:url(x)"},
            '<div style="--accent: ; width: 3px">x</div>', "invalid colors are dropped");
    }

    static function checksUrls():Void {
        var page = ["Page" => '<props url="String" /><a :href="url">x</a>'];
        var cases = [
            "/about" => '<a href="/about">x</a>',
            "https://example.com/a?b=1&c=2" => '<a href="https://example.com/a?b=1&amp;c=2">x</a>',
            "#top" => '<a href="#top">x</a>',
            "mailto:a@b.c" => '<a href="mailto:a@b.c">x</a>',
            "javascript:alert(1)" => '<a href="">x</a>',
            " JaVa\tScript:alert(1)" => '<a href="">x</a>',
            "data:text/html,x" => '<a href="">x</a>',
            "page.html" => '<a href="page.html">x</a>'
        ];
        for (url => expected in cases) {
            expect(page, "Page", {url: url}, expected, 'URL ${url}');
        }
        expect(page, "Page", {url: null}, '<a>x</a>', "a null bound URL omits the attribute");
        host.base = "/preview/7";
        expect(page, "Page", {url: "/about"}, '<a href="/preview/7/about">x</a>',
            "site URLs get the link base");
        expect(page, "Page", {url: "//cdn.example.com/x"}, '<a href="//cdn.example.com/x">x</a>',
            "protocol-relative URLs do not");
        var mixed = [
            "Page" =>
            '<props slug="String" /><a href="/content/{{ slug }}">x</a><a href="java{{ slug }}">y</a><a href="javascript:void(0)">z</a>'
        ];
        expect(mixed, "Page", {slug: "script:alert(1)"},
            '<a href="/preview/7/content/script:alert(1)">x</a><a href="">y</a><a href="">z</a>',
            "static URL starts decide the scheme; open starts are checked whole");
        host.base = "";
    }

    static function rendersBranchesAndLoops():Void {
        var page = [
            "Page" =>
            '<props items="List<Post>" mode="Int" />\n<p :if="mode == 1">one</p>\n<p :else-if="mode == 2">two</p>\n<p :else>many</p>\n<ul>\n  <li :for="post in items" :class="loop.last ? \'last\'">{{ loop.number }}/{{ loop.length }} {{ post.title }}<b :for="tag in post.tags">{{ loop.parent.index }}{{ tag }}</b></li>\n  <li :empty>none</li>\n</ul>'
        ];
        expect(page, "Page", {items: [post("A"), post("B")], mode: 2},
            '<p>two</p>\n<ul>\n<li>1/2 A<b>0a</b><b>0b</b></li><li class="last">2/2 B<b>1a</b><b>1b</b></li>\n</ul>',
            "branches, loops, loop metadata and nested loops");
        expect(page, "Page", {items: [], mode: 7}, '<p>many</p>\n<ul>\n<li>none</li>\n</ul>',
            "else and empty branches");
        expect(page, "Page", {items: null, mode: 1}, '<p>one</p>\n<ul>\n<li>none</li>\n</ul>',
            "a null list renders the empty branch");
        var narrowed = [
            "Page" =>
            '<props post="Post" /><img :if="post.image" src="{{ post.image }}" alt=""><template :for="tag in post.tags"><i>{{ tag }}</i></template>'
        ];
        expect(narrowed, "Page", {post: post("A", null, "/media/a.jpg")},
            '<img src="/media/a.jpg" alt=""><i>a</i><i>b</i>',
            "template groups and narrowed paths");
    }

    static function components():Map<String, String> {
        return [
            "Card" =>
            '<props post="Post" featured="Bool = false" label="String = \'Read\'" />\n<article class="card" :class="featured ? \'is-featured\'">\n  <h2><a href="{{ post.url }}">{{ post.title }}</a></h2>\n  <slot name="meta"><span>{{ post.minutes }} min</span></slot>\n  <slot />\n  <a href="{{ post.url }}">{{ label }}</a>\n</article>',
            "List" =>
            '<props items="List<Post>" />\n<ul><li :for="item in items"><slot name="row" :row="item" /></li></ul>',
            "Layout" =>
            '<props title="String" />\n<!doctype html>\n<html><head><HeadOutlet /><Assets /></head><body><Head><title>{{ title }}</title><meta name="layout" content="1"></Head><main><slot /></main></body></html>'
        ];
    }

    static function rendersComponentsAndSlots():Void {
        var templates = components();
        templates.set("Page",
            '<props items="List<Post>" />\n<Card :for="post in items" :post="post" :featured="loop.first" label="Más &amp; más">\n  <template slot="meta"><em>{{ loop.index }}</em></template>\n  <p>{{ post.excerpt ?? \'—\' }}</p>\n</Card>\n<Card :if="items[0]" :post="items[0]" />');
        var output = render(templates, "Page", {items: [post("A", "x"), post("B")]});
        var expected = '<article class="card is-featured">\n<h2><a href="/content/a">A</a></h2>\n<em>0</em>\n\n<p>x</p>\n\n<a href="/content/a">Más &amp; más</a>\n</article><article class="card">\n<h2><a href="/content/b">B</a></h2>\n<em>1</em>\n\n<p>—</p>\n\n<a href="/content/b">Más &amp; más</a>\n</article>\n<article class="card">\n<h2><a href="/content/a">A</a></h2>\n<span>3 min</span>\n\n<a href="/content/a">Read</a>\n</article>';
        check(output == expected,
            'components with props, defaults and slots: expected\n  ${expected}\ngot\n  ${output}');
        templates.set("Rows",
            '<props items="List<Post>" />\n<List :items="items"><template slot="row" :let="row"><b>{{ row.title }}</b></template></List>');
        expect(templates, "Rows", {items: [post("A"), post("B")]},
            '<ul><li><b>A</b></li><li><b>B</b></li></ul>', "scoped slots");
    }

    static function forwardsAttributes():Void {
        var templates = [
            "Button" =>
            '<props label="String" />\n<button class="button" :attrs>{{ label }}</button>',
            "Page" =>
            '<props on="Bool" />\n<Button label="Save" class="primary" :class="on ? \'is-on\'" data-id="7" aria-label="{{ t(\'Save it\') }}" />'
        ];
        expect(templates, "Page", {on: true},
            '<button class="button primary is-on" data-id="7" aria-label="Save it">Save</button>',
            "forwarded attributes and merged classes");
    }

    static function collectsHeadContent():Void {
        var templates = components();
        templates.set("Page",
            '<props items="List<Post>" />\n<Layout title="Fallback">\n  <Head><title>{{ items[0].title ?? \'none\' }} — {{ site.site_name }}</title><meta name="description" content="Recent"></Head>\n  <Card :if="items[0]" :post="items[0]"><Head><title>card</title></Head></Card>\n</Layout>');
        var output = render(templates, "Page", {items: [post("A")]});
        var expected = '<!doctype html>\n<html><head><title>A — Field &amp; Notes</title><meta name="layout" content="1"><meta name="description" content="Recent"></head><body><main>\n\n<article class="card">\n<h2><a href="/content/a">A</a></h2>\n<span>3 min</span>\n\n<a href="/content/a">Read</a>\n</article>\n</main></body></html>';
        check(output == expected,
            'head content and the page title win: expected\n  ${expected}\ngot\n  ${output}');
    }

    static function rendersFragments():Void {
        var templates = components();
        templates.set("Page",
            '<props items="List<Post>" />\n<Layout title="T">\n  <section fragment="list"><p :for="post in items">{{ post.title }}</p></section>\n  <form method="get" swap="list"><input name="q"></form>\n</Layout>');
        expect(templates, "Page", {items: [post("A"), post("B")]},
            '<section data-well-fragment="list"><p>A</p><p>B</p></section>',
            "a fragment renders alone", "list");
        expect(templates, "Page", {items: []}, '<missing>', "an unknown fragment is reported",
            "other");
        var full = render(templates, "Page", {items: []});
        check(full.indexOf('data-well-swap="list"') > 0
            && full.indexOf('<script type="module" src="/wellout.js" nonce="n0nce"></script></head>') > 0,
            'swaps load the client runtime (got ${full})');
    }

    static function rendersIslandsAndAssets():Void {
        var templates = components();
        templates.set("Page",
            '<Layout title="T">\n  <Asset css="card.css" /><Asset css="card.css" /><Asset js="extra.js" />\n  <Island name="uploader" :props="{ max: 5, label: \'</script><b>&\' }" load="visible"><p>Fallback</p></Island>\n</Layout>');
        var output = render(templates, "Page", {});
        check(output.indexOf('<well-island data-name="uploader" data-load="visible" data-module="/islands/uploader.js"><p>Fallback</p><script type="application/json" data-well-props nonce="n0nce">{"props":{"max":5,"label":"\\u003c/script\\u003e\\u003cb\\u003e\\u0026"},"messages":{"Upload":"Yükle"}}</script></well-island>') > 0,
            'island markup and escaped JSON (got ${output})');
        check(output.indexOf('<link rel="stylesheet" href="/assets/card.css"><script type="module" src="/assets/extra.js" nonce="n0nce"></script><script type="module" src="/wellout.js" nonce="n0nce"></script></head>') > 0,
            'assets are written once at <Assets /> with the runtime (got ${output})');
    }

    static function rendersForms():Void {
        var templates = [
            "Page" =>
            '<form method="post" action="/save"><button>Save</button></form><form method="DELETE" action="/x"></form><form action="/search"></form>'
        ];
        expect(templates, "Page", {},
            '<form method="post" action="/save"><input type="hidden" name="_token" value="tok&quot;en"><button>Save</button></form><form method="post" action="/x"><input type="hidden" name="_token" value="tok&quot;en"><input type="hidden" name="_method" value="DELETE"></form><form action="/search"></form>',
            "post forms get the CSRF field and method overrides");
    }

    static function loadsSources():Void {
        var templates = [
            "Page" =>
            '<props count="Int" />\n<sources recent="latest(limit: count)" />\n<p :for="post in recent">{{ post.title }}</p>'
        ];
        sourceCalls = 0;
        expect(templates, "Page", {count: 2}, '<p>Latest 0</p><p>Latest 1</p>',
            "sources are resolved before rendering");
        check(sourceCalls == 1, 'a source is loaded once per render (got ${sourceCalls})');
    }

    static function reportsTemplateProblems():Void {
        var templates = components();
        templates.set("A", '<Crad :post="x" />');
        expectProblem(templates, "A", "unknown-component", 1, 1, "unknown component");
        var hint = diagnosticsOf(templates, "A")[0].hint;
        check(hint == "Did you mean Card?", 'component suggestion (got ${hint})');
        templates.set("B", '<props items="List<Post>" />\n<Card :featured="true" />');
        expectProblem(templates, "B", "missing-prop", 2, 1, "missing prop");
        templates.set("C", '<props post="Post" />\n<Card :post="post" :featured="post.title" />');
        expectProblem(templates, "C", "prop-type", 2, 31, "prop type mismatch");
        templates.set("D", '<props items="List<Post>" />\n<Card :post="items[0]" />');
        expectProblem(templates, "D", "prop-type", 2, 14, "nullable value for a non-null prop");
        templates.set("E",
            '<props post="Post" />\n<Card :post="post"><template slot="footer">x</template></Card>');
        expectProblem(templates, "E", "unknown-slot", 2, 30, "unknown slot");
        templates.set("F", '<props post="Post" />\n<Card :post="post" titel="x" />');
        expectProblem(templates, "F", "unknown-prop", 2, 20, "unknown prop");
        templates.set("G",
            '<props items="List<Post>" />\n<p :for="post in items"><Head><title>{{ post.title }}</title></Head></p>');
        expectProblem(templates, "G", "head-scope", 2, 41, "head reads a loop variable");
        templates.set("H",
            '<props items="List<Post>" unused="Int" />\n<p :for="x in items">{{ x.title }}</p>');
        expectProblem(templates, "H", "unused-prop", 1, 27, "unused prop warning");
        templates.set("I", '<p fragment="a">1</p><p fragment="a">2</p>');
        expectProblem(templates, "I", "duplicate-fragment", 1, 25, "duplicate fragment");
        templates.set("J", '<props post="Post" />\n<p :for="x in post">{{ x }}</p>');
        expectProblem(templates, "J", "for-list-type", 2, 15, ":for over a record");
        templates.set("K", '<Island name="uploadr" />');
        expectProblem(templates, "K", "unknown-island", 1, 1, "unknown island");
        templates.set("L", '<props post="Post" />\n<p>{{ post }}</p>');
        expectProblem(templates, "L", "unprintable-value", 2, 7, "printing a record");
        templates.set("M", '<Head><div>x</div></Head>');
        expectProblem(templates, "M", "head-content", 1, 7, "head content");
        templates.set("N", '<N />');
        expectProblem(templates, "N", "recursive-component", 1, 1, "recursion");
        templates.set("O", '<props color="String" />\n<p style="color: {{ color }}">x</p>');
        expectProblem(templates, "O", "style-value", 2, 21, "untyped style value");
        templates.set("P",
            '<sources posts="latest(limit: t(\'x\'))" />\n<p>{{ posts[0].title }}</p>');
        expectProblem(templates, "P", "source-argument", 1, 31, "source arguments are static");
        templates.set("Q", '<props post="Post" />\n<Card :post="post" :let="x" />');
        expectProblem(templates, "Q", "slot-without-value", 2, 1, ":let on a slot without a value");
        var untrusted = new ComponentLibrary(contract, null, false);
        untrusted.add("R", '<script>alert(1)</script><iframe src="/x"></iframe>');
        var codes = [for (diagnostic in untrusted.check("R").diagnostics) diagnostic.code];
        check(codes.join(",") == "rejected-element,rejected-element",
            'untrusted templates reject scripts and frames (got ${codes.join(",")})');
    }

    #if jvm
    static function rendersPagesWithoutAllocating():Void {
        var templates = components();
        templates.set("Page",
            '<props items="List<Post>" />\n<Layout title="Home">\n  <Head><title>{{ t(\'Home\') }} — {{ site.site_name }}</title></Head>\n  <Card :for="post in items" :post="post" :featured="loop.first">\n    <p :if="post.excerpt">{{ post.excerpt | truncate(40) }}</p>\n    <ul><li :for="tag in post.tags" :class="loop.last ? \'last\'">{{ tag }}</li></ul>\n  </Card>\n</Layout>');
        var template = compiled(templates, "Page");
        if (template == null) {
            return;
        }
        var props = {
            items: [
                for (index in 0...24)
                    post('Post ${index} & more',
                        index % 3 == 0 ? null : 'Excerpt ${index} with some longer text to truncate')
            ]
        };
        var writer = new ByteWriter(64 * 1024);
        for (round in 0...20000) {
            writer.reset();
            Renderer.render(template, props, host, writer);
        }
        var counter:AllocationCounter = cast ManagementFactory.getThreadMXBean();
        var renders = 2000;
        var before = counter.getCurrentThreadAllocatedBytes();
        for (round in 0...renders) {
            writer.reset();
            Renderer.render(template, props, host, writer);
        }
        var allocated = Int64.toInt(counter.getCurrentThreadAllocatedBytes() - before);
        var perRender = allocated / renders;
        Sys.println('page render: ${writer.length} bytes, ${perRender} bytes allocated per render');
        check(perRender < 64,
            'a steady-state page render allocates almost nothing (${perRender} bytes)');
    }
    #end
}
