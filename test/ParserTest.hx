import haxe.Resource;
import wellout.syntax.Ast;
import wellout.syntax.AstPrinter;
import wellout.syntax.Diagnostic;
import wellout.syntax.Parser;

using StringTools;

class ParserTest {
    static var check:(Bool, String) -> Void;

    public static function run(assert:(Bool, String) -> Void):Void {
        check = assert;
        parsesTextAndInterpolation();
        parsesAttributesBindingsAndDirectives();
        parsesVoidElementsAndComponents();
        parsesDeclarations();
        keepsRawTextAndVerbatimContent();
        scansInterpolationQuotes();
        parsesDocumentShellAndSvg();
        parsesThemeBuildingBlocks();
        dropsComments();
        parsesSpecificationExamples();
        reportsUnclosedElements();
        reportsMismatchedClosingTags();
        reportsAttributeProblems();
        reportsSelfClosingHtml();
        reportsMisplacedBranches();
        reportsIfWithFor();
        reportsUnterminatedInterpolation();
        reportsDeclarationProblems();
        reportsInvalidLoops();
        formatsDiagnostics();
    }

    static function expectTree(source:String, expected:String, label:String):Void {
        var result = Parser.parse(source);
        var printed = AstPrinter.print(result.document);
        var codes = [for (diagnostic in result.diagnostics) diagnostic.code];
        check(codes.length == 0, '${label}: no diagnostics (got ${codes.join(", ")})');
        check(printed == expected, '${label}: expected\n  ${expected}\ngot\n  ${printed}');
    }

    static function expectDiagnostic(source:String, code:String, line:Int, column:Int,
            label:String):Void {
        var result = Parser.parse(source);
        var found = result.diagnostics.filter(diagnostic -> diagnostic.code == code);
        var all = [
            for (diagnostic in result.diagnostics)
                '${diagnostic.code}@${diagnostic.position}'
        ];
        check(found.length > 0, '${label}: expected ${code} (got ${all.join(", ")})');
        if (found.length > 0) {
            var position = found[0].position;
            check(position.line == line && position.column == column,
                '${label}: expected ${code} at ${line}:${column}, got ${position}');
        }
    }

    static function parsesTextAndInterpolation():Void {
        expectTree('<p class="lead">Hello {{ name }}!</p>', '(p class="lead" "Hello {name}!")',
            "text with interpolation");
    }

    static function parsesAttributesBindingsAndDirectives():Void {
        expectTree('<li :for="tag in item.tags" :key="tag.id"><a href="{{ tag.url }}">{{ tag.name }}</a></li>',
            '(li :for={tag in item.tags} :key={tag.id} (a href="{tag.url}" "{tag.name}"))',
            "loop with binding");
        expectTree('<input name="email" required :disabled="not can(\'subscribe\')" />',
            '(input name="email" required :disabled={not can(\'subscribe\')})',
            "boolean and bound attributes");
        expectTree('<article class="card {{ featured ? \'is-featured\' }}"></article>',
            '(article class="card {featured ? \'is-featured\'}")',
            "interpolation inside an attribute");
    }

    static function parsesVoidElementsAndComponents():Void {
        var source = '<img src="{{ post.image }}" alt=""><br /><PostCard :post="post" /><newsletter:Signup :list="\'main\'" />';
        expectTree(source,
            '(img src="{post.image}" alt="") (br) (PostCard :post={post}) (newsletter:Signup :list={\'main\'})',
            "void elements and components");
        var result = Parser.parse(source);
        var kinds = [
            for (node in result.document.children)
                switch node {
                    case Element(element):
                        Std.string(element.kind);
                    default:
                        "";
                }
        ];
        check(kinds.join(",") == "VoidElement,VoidElement,ComponentElement,ComponentElement",
            'element kinds (got ${kinds.join(",")})');
    }

    static function parsesDeclarations():Void {
        var source = '<props post="ContentSummary" featured="Bool = false" />\n<sources travel="entries(limit: 3)" />\n\n<article>x</article>';
        expectTree(source,
            'props post=ContentSummary\nprops featured=Bool = false\nsources travel=entries(limit: 3)\n(article "x")',
            "props and sources declarations");
        var document = Parser.parse(source).document;
        check(document.props[1].valuePosition.line == 1
            && document.props[1].valuePosition.column == 40,
            'declaration value position (got ${document.props[1].valuePosition})');
    }

    static function keepsRawTextAndVerbatimContent():Void {
        expectTree('<style>a::before { content: "{{" }</style>',
            '(style "a::before { content: "{{" }")', "raw text is not interpolated");
        expectTree('<pre :verbatim>{{ not.parsed }}</pre>', '(pre :verbatim "{{ not.parsed }}")',
            "verbatim text");
    }

    static function scansInterpolationQuotes():Void {
        expectTree('<p>{{ a < b ? \'}}\' : "x" }}</p>', '(p "{a < b ? \'}}\' : "x"}")',
            "quotes and comparisons inside interpolation");
    }

    static function parsesDocumentShellAndSvg():Void {
        expectTree('<!doctype html><html lang="{{ locale.code }}"><head><HeadOutlet /></head><body><slot /></body></html>',
            '<!doctype> (html lang="{locale.code}" (head (HeadOutlet)) (body (slot)))',
            "layout shell");
        expectTree('<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M0 0L10 10" fill="none" /></svg>',
            '(svg viewBox="0 0 10 10" aria-hidden="true" (path d="M0 0L10 10" fill="none"))',
            "self-closing elements inside SVG");
    }

    static function parsesThemeBuildingBlocks():Void {
        expectTree('<details class="menu"><summary>{{ t(\'Menu\') }}</summary><Navigation region="header" /></details>',
            '(details class="menu" (summary "{t(\'Menu\')}") (Navigation region="header"))',
            "menu without JavaScript");
        expectTree('<Head><title>{{ item.title }} — {{ site.site_name }}</title><meta name="description" content="{{ item.excerpt }}" /></Head>',
            '(Head (title "{item.title} — {site.site_name}") (meta name="description" content="{item.excerpt}"))',
            "head content");
    }

    static function dropsComments():Void {
        expectTree('<p><!-- note -->x</p>', '(p "x")', "comments are removed");
    }

    static function parsesSpecificationExamples():Void {
        var card = Resource.getString("fixture.PostCard");
        check(!Parser.parse(card).hasErrors(), "SPEC A.1 component parses without diagnostics");
        var home = Resource.getString("fixture.Home");
        var result = Parser.parse(home);
        check(!result.hasErrors(), "SPEC A.2 page parses without diagnostics");
        check(result.document.props.length == 2 && result.document.sources.length == 1,
            "SPEC A.2 declarations are collected");
    }

    static function reportsUnclosedElements():Void {
        expectDiagnostic('<div>\n  <p>text\n</div>', "unclosed-element", 2, 3, "unclosed child");
        expectDiagnostic('<section>', "unclosed-element", 1, 1, "unclosed at end of file");
    }

    static function reportsMismatchedClosingTags():Void {
        expectDiagnostic('<div></span></div>', "unexpected-closing-tag", 1, 6, "stray closing tag");
        expectDiagnostic('</p>', "unexpected-closing-tag", 1, 1, "closing tag at top level");
    }

    static function reportsAttributeProblems():Void {
        expectDiagnostic('<input value=unquoted>', "unquoted-attribute", 1, 14, "unquoted value");
        expectDiagnostic('<p class="a" class="b">x</p>', "duplicate-attribute", 1, 14,
            "duplicate attribute");
        expectDiagnostic('<p title="a" :title="b">x</p>', "duplicate-attribute", 1, 14,
            "static and bound attribute with one name");
        expectDiagnostic('<button onclick="go()">x</button>', "event-attribute", 1, 9,
            "event handler");
        expectDiagnostic('<button :onClick="go">x</button>', "event-attribute", 1, 9,
            "bound event handler");
        check(!Parser.parse('<Card onlyNew="yes" />').hasErrors(),
            "component props starting with on are allowed");
        check(!Parser.parse('<p class="card" :class="extra">x</p>').hasErrors(),
            "a static class and a bound :class combine");
        expectDiagnostic('<p :class="a" :class="b">x</p>', "duplicate-attribute", 1, 15,
            "two bound classes");
    }

    static function reportsSelfClosingHtml():Void {
        expectDiagnostic('<div />', "self-closing-html", 1, 1, "self-closing div");
    }

    static function reportsMisplacedBranches():Void {
        expectDiagnostic('<p :else>x</p>', "misplaced-else", 1, 4, ":else without :if");
        expectDiagnostic('<p :if="a">a</p>text<p :else>b</p>', "misplaced-else", 1, 24,
            "text between branches");
        check(!Parser.parse('<p :if="a">a</p>\n  <p :else-if="b">b</p>\n  <p :else>c</p>')
            .hasErrors(),
            "a branch chain separated by whitespace is valid");
        expectDiagnostic('<ul><li :empty>none</li></ul>', "misplaced-empty", 1, 9,
            ":empty without :for");
        check(!Parser.parse('<li :for="x in xs">{{ x }}</li><li :empty>none</li>').hasErrors(),
            ":empty after :for is valid");
    }

    static function reportsIfWithFor():Void {
        expectDiagnostic('<li :if="a" :for="x in xs">x</li>', "if-with-for", 1, 5, ":if with :for");
    }

    static function reportsUnterminatedInterpolation():Void {
        expectDiagnostic('<p>{{ name </p>', "unterminated-interpolation", 1, 4,
            "unterminated interpolation");
        expectDiagnostic('<p>{{   }}</p>', "empty-interpolation", 1, 4, "empty interpolation");
    }

    static function reportsDeclarationProblems():Void {
        expectDiagnostic('<props> post: ContentSummary </props>', "invalid-declaration", 1, 1,
            "newline-style props from draft 0.1");
        expectDiagnostic('<article><props post="X" /></article>', "misplaced-declaration", 1, 10,
            "nested props");
        expectDiagnostic('<p>x</p>\n<props post="X" />', "misplaced-declaration", 2, 1,
            "props after markup");
    }

    static function reportsInvalidLoops():Void {
        expectDiagnostic('<li :for="tag of tags">x</li>', "invalid-for", 1, 11, ":for with of");
        expectDiagnostic('<li :for>x</li>', "missing-directive-value", 1, 5,
            ":for without a value");
    }

    static function formatsDiagnostics():Void {
        var source = '<div>\n  <p>text\n</div>';
        var diagnostic = Parser.parse(source).diagnostics[0];
        var formatted = diagnostic.format(source, "card.well.html");
        check(formatted.startsWith("card.well.html:2:3: Element <p> is not closed before </div> [unclosed-element]"),
            'formatted diagnostic header (got ${formatted.split("\n")[0]})');
        check(formatted.indexOf("\n      ^") > 0 && formatted.indexOf("hint: Add </p>") > 0,
            "formatted diagnostic caret and hint");
    }
}
