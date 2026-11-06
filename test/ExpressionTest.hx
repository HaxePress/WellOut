import haxe.Resource;
import wellout.syntax.Ast;
import wellout.syntax.Diagnostic;
import wellout.syntax.Expr;
import wellout.syntax.ExprPrinter;
import wellout.syntax.ExpressionParser;
import wellout.syntax.Parser;
import wellout.syntax.Position;

class ExpressionTest {
    static var check:(Bool, String) -> Void;

    public static function run(assert:(Bool, String) -> Void):Void {
        check = assert;
        parsesLiterals();
        parsesPaths();
        parsesCallsAndFilters();
        parsesArithmetic();
        parsesLogic();
        parsesConditionals();
        parsesCollections();
        mapsPositions();
        reportsLexicalProblems();
        reportsSyntaxProblems();
        parsesLoops();
        parsesTypesAndProps();
        positionsTemplateExpressions();
        parsesFixtureExpressions();
    }

    static function expectExpression(source:String, expected:String, label:String):Void {
        var result = ExpressionParser.parse(source);
        check(result.value != null && result.diagnostics.length == 0,
            '${label}: no diagnostics (got ${summary(result.diagnostics)})');
        if (result.value != null) {
            var printed = ExprPrinter.print(result.value);
            check(printed == expected, '${label}: expected ${expected}, got ${printed}');
        }
    }

    static function expectDiagnostic(diagnostics:Array<Diagnostic>, code:String, line:Int,
            column:Int, label:String):Null<Diagnostic> {
        var found = diagnostics.filter(diagnostic -> diagnostic.code == code);
        check(found.length > 0, '${label}: expected ${code} (got ${summary(diagnostics)})');
        if (found.length == 0) {
            return null;
        }
        var position = found[0].position;
        check(position.line == line && position.column == column,
            '${label}: expected ${code} at ${line}:${column}, got ${position}');
        return found[0];
    }

    static function summary(diagnostics:Array<Diagnostic>):String {
        var printed = [for (item in diagnostics) '${item.code}@${item.position}'];
        return printed.join(", ");
    }

    static function expectProblem(source:String, code:String, column:Int,
            label:String):Null<Diagnostic> {
        return expectDiagnostic(ExpressionParser.parse(source).diagnostics, code, 1, column, label);
    }

    static function parsesLiterals():Void {
        expectExpression("'a'", "'a'", "single-quoted string");
        expectExpression('"b"', "'b'", "double-quoted string");
        expectExpression("'it\\'s'", "'it\\'s'", "escaped quote");
        expectExpression("'{{'", "'{{'", "braces inside a string");
        expectExpression("'a\\nb'", "'a\\nb'", "newline escape");
        expectExpression("'say \\u0022hi\\u0022'", "'say \"hi\"'", "unicode escape");
        expectExpression("42", "42", "integer");
        expectExpression("1.5", "1.5", "decimal");
        expectExpression("2.0", "2.0", "decimal with a zero fraction");
        expectExpression("true", "true", "true");
        expectExpression("false", "false", "false");
        expectExpression("null", "null", "null");
    }

    static function parsesPaths():Void {
        expectExpression("post.title", "post.title", "field path");
        expectExpression("items[0].title", "items[0].title", "index then field");
        expectExpression("map[key]", "map[key]", "computed index");
        expectExpression("a.b[c.d].e", "a.b[c.d].e", "nested path in an index");
        expectExpression("loop.index", "loop.index", "loop metadata");
        var result = ExpressionParser.parse("post.title");
        switch result.value.kind {
            case Path(root, [Field(name, position)]):
                check(root == "post" && name == "title" && position.column == 6,
                    'field segment position (got ${position})');
            default:
                check(false, "a field path is a Path with one Field segment");
        }
    }

    static function parsesCallsAndFilters():Void {
        expectExpression("t('Subscribe')", "t('Subscribe')", "helper call");
        expectExpression("t()", "t()", "call without arguments");
        expectExpression("t('x', name: value, count: 3)", "t('x', name: value, count: 3)",
            "named arguments");
        expectExpression("post.excerpt | truncate(160)", "(post.excerpt | truncate(160))",
            "filter with an argument");
        expectExpression("name | lower | upper", "((name | lower) | upper)", "chained filters");
        expectExpression("post.published_at | date('iso')", "(post.published_at | date('iso'))",
            "date filter");
        expectExpression("price | number(style: 'currency')",
            "(price | number(style: 'currency'))", "filter with a named argument");
        var result = ExpressionParser.parse("post.excerpt | truncate(160)");
        switch result.value.kind {
            case Filter(_, name, arguments, position):
                check(name == "truncate" && arguments.length == 1 && position.column == 16,
                    'filter name position (got ${position})');
            default:
                check(false, "a filtered expression is a Filter");
        }
    }

    static function parsesArithmetic():Void {
        expectExpression("a + b * c", "(a + (b * c))", "multiplication binds tighter");
        expectExpression("(a + b) * c", "((a + b) * c)", "parentheses");
        expectExpression("-a * b", "((-a) * b)", "negation binds tighter than multiplication");
        expectExpression("a - -b", "(a - (-b))", "negated right operand");
        expectExpression("a % 2 == 0", "((a % 2) == 0)", "modulo inside a comparison");
        expectExpression("a + b | upper", "(a + (b | upper))", "filters bind tighter than +");
        expectExpression("-1", "(-1)", "negative literal");
        expectExpression("a / b - c", "((a / b) - c)", "left associativity");
        expectExpression("a - b - c", "((a - b) - c)", "subtraction is left associative");
    }

    static function parsesLogic():Void {
        expectExpression("not a == b", "(not (a == b))", "not binds looser than ==");
        expectExpression("a and b or c", "((a and b) or c)", "and binds tighter than or");
        expectExpression("a or b and c", "(a or (b and c))", "or with and on the right");
        expectExpression("x in xs", "(x in xs)", "membership");
        expectExpression("not x in xs", "(not (x in xs))", "not with membership");
        expectExpression("a < b and c >= d", "((a < b) and (c >= d))", "two comparisons");
        expectExpression("a != b", "(a != b)", "inequality");
        expectExpression("not a and not b", "((not a) and (not b))", "not on both operands");
    }

    static function parsesConditionals():Void {
        expectExpression("a ?? b ?? c", "((a ?? b) ?? c)", "coalesce is left associative");
        expectExpression("a ? b : c", "(a ? b : c)", "conditional");
        expectExpression("featured ? 'is-featured'", "(featured ? 'is-featured')",
            "conditional without an alternative");
        expectExpression("a ? b : c ? d : e", "(a ? b : (c ? d : e))",
            "conditional is right associative");
        expectExpression("a ?? b ? c : d", "((a ?? b) ? c : d)", "coalesce inside a condition");
        expectExpression("a == b ? 'x' : 'y'", "((a == b) ? 'x' : 'y')",
            "comparison as a condition");
        expectExpression("a or b ? 1 : 2", "((a or b) ? 1 : 2)", "or as a condition");
        expectExpression("t(flag ? 'a' : 'b')", "t((flag ? 'a' : 'b'))",
            "conditional as an argument");
        expectExpression("a ? b ? c : d", "(a ? (b ? c : d))", "nested consequent");
    }

    static function parsesCollections():Void {
        expectExpression("[]", "[]", "empty list");
        expectExpression("[1, 2]", "[1, 2]", "list");
        expectExpression("['a', b]", "['a', b]", "mixed list");
        expectExpression("{ list: 'main' }", "{ list: 'main' }", "record");
        expectExpression("{}", "{}", "empty record");
        expectExpression("{a: 1, b: [2]}", "{ a: 1, b: [2] }", "record with a list");
        expectExpression("[a ? b : c]", "[(a ? b : c)]", "conditional in a list");
        expectExpression("{ key: a ? b : c }", "{ key: (a ? b : c) }", "conditional in a record");
    }

    static function mapsPositions():Void {
        var base = new Position(100, 5, 10);
        var result = ExpressionParser.parse("{\n  list: 'main',\n  count: 3 }", base);
        check(result.value != null && result.value.position.offset == 100
            && result.value.position.line == 5 && result.value.position.column == 10,
            "the expression starts at the base position");
        switch result.value.kind {
            case RecordLiteral(entries):
                var first = entries[0].position;
                var second = entries[1].position;
                check(first.offset == 104 && first.line == 6 && first.column == 3,
                    'first entry on the next line (got ${first.offset} ${first})');
                check(second.offset == 120 && second.line == 7 && second.column == 3,
                    'second entry two lines down (got ${second.offset} ${second})');
            default:
                check(false, "a multi-line record parses");
        }
        expectDiagnostic(ExpressionParser.parse("a\n  +").diagnostics, "expected-expression", 2,
            4, "diagnostic on the second line");
        expectDiagnostic(ExpressionParser.parse("a +", new Position(50, 3, 7)).diagnostics,
            "expected-expression", 3, 10, "diagnostic column offset by the base");
    }

    static function reportsLexicalProblems():Void {
        var and = expectProblem("a && b", "unexpected-character", 3, "&&");
        check(and != null && and.hint == "Use 'and' instead of '&&'", "&& suggests and");
        expectProblem("a || b", "unexpected-character", 3, "||");
        var not = expectProblem("!a", "unexpected-character", 1, "!");
        check(not != null && not.hint == "Use 'not' instead of '!'", "! suggests not");
        expectProblem("a === b", "unexpected-character", 3, "===");
        expectProblem("a # b", "unexpected-character", 3, "stray character");
        expectProblem("'abc", "unterminated-string", 1, "unterminated string");
        expectProblem("'a\\qb'", "invalid-escape", 3, "unknown escape");
        expectProblem("12px", "invalid-number", 1, "number with a suffix");
        expectProblem("99999999999", "integer-overflow", 1, "integer overflow");
        expectExpression("2147483647", "2147483647", "largest integer");
    }

    static function reportsSyntaxProblems():Void {
        expectProblem("", "expected-expression", 1, "empty expression");
        expectProblem("a +", "expected-expression", 4, "missing right operand");
        expectProblem("a b", "unexpected-token", 3, "two expressions");
        expectProblem("(a", "expected-token", 3, "unclosed parenthesis");
        expectProblem("a < b < c", "chained-comparison", 7, "chained comparison");
        var assignment = expectProblem("a = b", "unexpected-token", 3, "single equals");
        check(assignment != null && assignment.hint == "Use == to compare",
            "single equals suggests ==");
        expectProblem("t('x').length", "field-on-call", 7, "field on a call");
        expectProblem("t(name: 1, 'x')", "positional-after-named", 12,
            "positional after named argument");
        expectProblem("{ a: 1, a: 2 }", "duplicate-key", 9, "duplicate record key");
        expectProblem("and", "unexpected-keyword", 1, "keyword as an expression");
        expectProblem("not not a", "unexpected-keyword", 5, "repeated not");
        expectProblem("a |", "expected-filter-name", 4, "missing filter name");
        expectProblem("a.", "expected-field", 3, "missing field name");
        expectProblem("{ a 1 }", "expected-token", 5, "record without a colon");
        expectProblem("[1, 2", "expected-token", 6, "unclosed list");
        expectProblem("a ? ", "expected-expression", 5, "conditional without a consequent");
        expectProblem("[a, b][0]", "unexpected-token", 7, "index on a list literal");
        expectProblem("items[]", "expected-expression", 7, "empty index");
        expectProblem("1.", "unexpected-token", 2, "trailing dot");
    }

    static function parsesLoops():Void {
        var loop = ExpressionParser.parseLoop("item in items");
        check(loop.value != null && ExprPrinter.printLoop(loop.value) == "item in items"
            && loop.value.variablePosition.column == 1,
            "simple loop");
        var nested = ExpressionParser.parseLoop("tag in item.tags");
        check(nested.value != null && ExprPrinter.printLoop(nested.value) == "tag in item.tags",
            "loop over a path");
        var literal = ExpressionParser.parseLoop("x in [1, 2]");
        check(literal.value != null && ExprPrinter.printLoop(literal.value) == "x in [1, 2]",
            "loop over a list literal");
        expectDiagnostic(ExpressionParser.parseLoop("in items").diagnostics, "invalid-for", 1, 1,
            "loop without a variable");
        expectDiagnostic(ExpressionParser.parseLoop("item of items").diagnostics, "invalid-for",
            1, 6, "loop with of");
        expectDiagnostic(ExpressionParser.parseLoop("true in items").diagnostics, "invalid-for",
            1, 1, "keyword as a loop variable");
        expectDiagnostic(ExpressionParser.parseLoop("item in").diagnostics, "expected-expression",
            1, 8, "loop without a list");
        expectDiagnostic(ExpressionParser.parseLoop("item in items extra").diagnostics,
            "unexpected-token", 1, 15, "loop with trailing text");
    }

    static function parsesTypesAndProps():Void {
        var types = [
            "ContentSummary",
            "List<ContentSummary>",
            "Map<String, Int>?",
            "Map<String, List<Int>>",
            "Bool"
        ];
        for (source in types) {
            var result = ExpressionParser.parseType(source);
            check(result.value != null && ExprPrinter.printType(result.value) == source,
                'type ${source} round-trips');
        }
        var props = [
            "Bool = false" => "Bool = false",
            "ContentSummary?" => "ContentSummary?",
            "List<Int>=[]" => "List<Int> = []",
            "String = t('x')" => "String = t('x')",
            "Int = -1" => "Int = (-1)"
        ];
        for (source => expected in props) {
            var result = ExpressionParser.parseProp(source);
            var printed = result.value == null ? "" : ExprPrinter.printProp(result.value);
            check(printed == expected, 'prop ${source}: expected ${expected}, got ${printed}');
        }
        expectDiagnostic(ExpressionParser.parseType("List<").diagnostics, "expected-type", 1, 6,
            "unclosed type parameters");
        expectDiagnostic(ExpressionParser.parseType("List<A>>").diagnostics, "unexpected-token",
            1, 8, "extra closing angle bracket");
        expectDiagnostic(ExpressionParser.parseProp("= 1").diagnostics, "expected-type", 1, 1,
            "default without a type");
        expectDiagnostic(ExpressionParser.parseProp("Int = ").diagnostics, "expected-expression",
            1, 7, "missing default value");
    }

    static function positionsTemplateExpressions():Void {
        var directive = directiveOf('<p :if=" a ">x</p>', If);
        switch directive.kind {
            case Directive(_, source, position):
                check(source == "a" && position.line == 1 && position.column == 10,
                    'directive expression position (got ${source} at ${position})');
            default:
                check(false, ":if is a directive");
        }
        var binding = Parser.parse('<Card :post="\n  post\n" />').document.children[0];
        switch binding {
            case Element(element):
                switch element.attributes[0].kind {
                    case Binding(source, position):
                        check(source == "post" && position.line == 2 && position.column == 3,
                            'binding expression position (got ${source} at ${position})');
                    default:
                        check(false, ":post is a binding");
                }
            default:
                check(false, "the card is an element");
        }
        var template = '<p :if="x and">x</p>';
        var broken = directiveOf(template, If);
        switch broken.kind {
            case Directive(_, source, position):
                var result = ExpressionParser.parse(source, position);
                var diagnostic = expectDiagnostic(result.diagnostics, "expected-expression", 1,
                    14, "expression diagnostic mapped into the template");
                if (diagnostic != null) {
                    var formatted = diagnostic.format(template, "page.well.html");
                    check(StringTools.startsWith(formatted, "page.well.html:1:14: ")
                        && formatted.indexOf('\n    ${template}\n') > 0
                        && formatted.indexOf("\n                 ^") > 0,
                        'formatted expression diagnostic (got ${formatted})');
                }
            default:
                check(false, "the broken :if is a directive");
        }
    }

    /** Every expression in the specification fixtures parses from its template position. **/
    static function parsesFixtureExpressions():Void {
        for (name in ["fixture.PostCard", "fixture.Home"]) {
            var document = Parser.parse(Resource.getString(name)).document;
            var problems:Array<String> = [];
            var visited = 0;
            for (declaration in document.props) {
                visited++;
                var result = ExpressionParser.parseProp(declaration.value,
                    declaration.valuePosition);
                collect(result.diagnostics, problems);
            }
            for (declaration in document.sources) {
                visited++;
                var result = ExpressionParser.parse(declaration.value, declaration.valuePosition);
                collect(result.diagnostics, problems);
                check(result.value != null && result.value.kind.match(Call(_, _)),
                    '${name}: source ${declaration.name} is a call');
            }
            visited += walk(document.children, problems);
            check(problems.length == 0,
                '${name}: every expression parses (${problems.join("; ")})');
            check(visited >= 8, '${name}: fixture expressions were visited (${visited})');
        }
    }

    static function walk(nodes:Array<Node>, problems:Array<String>):Int {
        var visited = 0;
        for (node in nodes) {
            switch node {
                case Element(element):
                    for (attribute in element.attributes) {
                        switch attribute.kind {
                            case StaticValue(parts):
                                visited += walkParts(parts, problems);
                            case Binding(source, position):
                                visited++;
                                collect(ExpressionParser.parse(source, position).diagnostics,
                                    problems);
                            case Directive(If | ElseIf, source, position):
                                visited++;
                                collect(ExpressionParser.parse(source, position).diagnostics,
                                    problems);
                            case Directive(For, source, position):
                                visited++;
                                collect(ExpressionParser.parseLoop(source, position).diagnostics,
                                    problems);
                            default:
                        }
                    }
                    visited += walk(element.children, problems);
                case Text(text):
                    visited += walkParts(text.parts, problems);
                case Doctype(_, _):
            }
        }
        return visited;
    }

    static function walkParts(parts:Array<TextPart>, problems:Array<String>):Int {
        var visited = 0;
        for (part in parts) {
            switch part {
                case Interpolation(source, position):
                    visited++;
                    collect(ExpressionParser.parse(source, position).diagnostics, problems);
                case Literal(_):
            }
        }
        return visited;
    }

    static function collect(diagnostics:Array<Diagnostic>, problems:Array<String>):Void {
        for (diagnostic in diagnostics) {
            problems.push('${diagnostic.code}@${diagnostic.position}: ${diagnostic.message}');
        }
    }

    static function directiveOf(source:String, kind:DirectiveKind):Attribute {
        return switch Parser.parse(source).document.children[0] {
            case Element(element):
                element.directive(kind);
            default:
                null;
        }
    }
}
