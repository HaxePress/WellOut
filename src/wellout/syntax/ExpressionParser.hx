package wellout.syntax;

import wellout.syntax.Expr;
import wellout.syntax.Lexer;

/** A parse outcome: the value when parsing succeeded, and every diagnostic found. */
class Parsed<T> {
    public final value:Null<T>;
    public final diagnostics:Array<Diagnostic>;

    public function new(value:Null<T>, diagnostics:Array<Diagnostic>) {
        this.value = value;
        this.diagnostics = diagnostics;
    }

    public function hasErrors():Bool {
        return diagnostics.length > 0;
    }
}

/** Thrown after a diagnostic is recorded; an expression stops at its first problem. */
private class ParseFailure {
    public function new() {}
}

/**
    Parses expressions (SPEC §4.1), loop headers, prop declarations and type
    syntax. Each entry point takes the source kept by the template parser and
    the position where it starts, so diagnostics point into the template.
    Parsing stops at the first problem of an expression; the template parser
    collects problems across expressions.
**/
class ExpressionParser {
    static final keywords:Map<String, Bool> = [
        "and" => true,
        "or" => true,
        "not" => true,
        "in" => true,
        "true" => true,
        "false" => true,
        "null" => true
    ];
    static final comparisons:Map<String, BinaryOperator> = [
        "==" => Equal,
        "!=" => NotEqual,
        "<" => Less,
        "<=" => LessOrEqual,
        ">" => Greater,
        ">=" => GreaterOrEqual
    ];
    static final additiveOperations:Map<String, BinaryOperator> = ["+" => Add, "-" => Subtract];
    static final multiplicativeOperations:Map<String,
        BinaryOperator> = ["*" => Multiply, "/" => Divide, "%" => Modulo];
    static final loopHint = 'Write :for="item in items"';

    final lexer:Lexer;
    final diagnostics:Array<Diagnostic>;
    var tokens:Array<Token> = [];
    var index = 0;

    public static function parse(source:String, ?base:Position):Parsed<Expr> {
        var parser = new ExpressionParser(source, base);
        return parser.run(() -> {
            var expression = parser.expression();
            parser.expectEnd();
            return expression;
        });
    }

    /** `name in list`, the value of a `:for` directive. */
    public static function parseLoop(source:String, ?base:Position):Parsed<LoopSyntax> {
        var parser = new ExpressionParser(source, base);
        return parser.run(() -> parser.loop());
    }

    public static function parseType(source:String, ?base:Position):Parsed<TypeSyntax> {
        var parser = new ExpressionParser(source, base);
        return parser.run(() -> {
            var type = parser.type();
            parser.expectEnd();
            return type;
        });
    }

    /** `Type` or `Type = default`, the value of a `<props>` attribute. */
    public static function parseProp(source:String, ?base:Position):Parsed<PropSyntax> {
        var parser = new ExpressionParser(source, base);
        return parser.run(() -> parser.prop());
    }

    function new(source:String, base:Null<Position>) {
        lexer = new Lexer(source, base == null ? new Position(0, 1, 1) : base);
        diagnostics = lexer.diagnostics;
    }

    function run<T>(read:() -> T):Parsed<T> {
        var lexed = lexer.tokenize();
        if (lexed == null) {
            return new Parsed(null, diagnostics);
        }
        tokens = lexed;
        try {
            return new Parsed(read(), diagnostics);
        } catch (failure:ParseFailure) {
            return new Parsed(null, diagnostics);
        }
    }

    function expression():Expr {
        var condition = coalesce();
        if (!acceptSymbol("?")) {
            return condition;
        }
        var consequent = expression();
        var alternative = acceptSymbol(":") ? expression() : null;
        return new Expr(Conditional(condition, consequent, alternative), condition.position);
    }

    function coalesce():Expr {
        var left = or();
        while (isSymbol("??")) {
            var at = tokenPosition();
            advance();
            left = new Expr(Binary(Coalesce, left, or(), at), left.position);
        }
        return left;
    }

    function or():Expr {
        var left = and();
        while (isWord("or")) {
            var at = tokenPosition();
            advance();
            left = new Expr(Binary(Or, left, and(), at), left.position);
        }
        return left;
    }

    function and():Expr {
        var left = not();
        while (isWord("and")) {
            var at = tokenPosition();
            advance();
            left = new Expr(Binary(And, left, not(), at), left.position);
        }
        return left;
    }

    function not():Expr {
        if (isWord("not")) {
            var at = tokenPosition();
            advance();
            return new Expr(Unary(Not, comparison()), at);
        }
        return comparison();
    }

    function comparison():Expr {
        var left = additive();
        var operation = comparisonOperator();
        if (operation == null) {
            return left;
        }
        var at = tokenPosition();
        advance();
        var right = additive();
        if (comparisonOperator() != null) {
            fail("chained-comparison", "Comparisons cannot be chained",
                "Combine two comparisons with 'and'");
        }
        return new Expr(Binary(operation, left, right, at), left.position);
    }

    function comparisonOperator():Null<BinaryOperator> {
        return isWord("in") ? In : symbolOperation(comparisons);
    }

    function additive():Expr {
        return leftAssociative(additiveOperations, multiplicative);
    }

    function multiplicative():Expr {
        return leftAssociative(multiplicativeOperations, unary);
    }

    /** `operand { symbol operand }` for one precedence level, folded to the left. **/
    function leftAssociative(operations:Map<String, BinaryOperator>, operand:() -> Expr):Expr {
        var left = operand();
        while (true) {
            var operation = symbolOperation(operations);
            if (operation == null) {
                return left;
            }
            var at = tokenPosition();
            advance();
            left = new Expr(Binary(operation, left, operand(), at), left.position);
        }
    }

    function symbolOperation(operations:Map<String, BinaryOperator>):Null<BinaryOperator> {
        return switch current().kind {
            case Symbol(text):
                operations.get(text);
            default:
                null;
        }
    }

    function unary():Expr {
        if (isSymbol("-")) {
            var at = tokenPosition();
            advance();
            return new Expr(Unary(Negate, filtered()), at);
        }
        return filtered();
    }

    function filtered():Expr {
        var target = primary();
        while (acceptSymbol("|")) {
            var at = tokenPosition();
            var name = switch current().kind {
                case Word(name):
                    advance();
                    name;
                default:
                    fail("expected-filter-name",
                        'Expected a filter name after | but found ${describe(current())}');
            }
            var arguments = isSymbol("(") ? argumentList() : [];
            target = new Expr(Filter(target, name, arguments, at), target.position);
        }
        return target;
    }

    function primary():Expr {
        var token = current();
        var at = tokenPosition();
        switch token.kind {
            case Text(value):
                advance();
                return new Expr(StringLiteral(value), at);
            case Integer(value):
                advance();
                return new Expr(IntLiteral(value), at);
            case Decimal(value):
                advance();
                return new Expr(FloatLiteral(value), at);
            case Word("true"):
                advance();
                return new Expr(BoolLiteral(true), at);
            case Word("false"):
                advance();
                return new Expr(BoolLiteral(false), at);
            case Word("null"):
                advance();
                return new Expr(NullLiteral, at);
            case Word(name) if (keywords.exists(name)):
                return fail("unexpected-keyword", 'Unexpected keyword ${name}');
            case Word(name):
                advance();
                if (isSymbol("(")) {
                    var arguments = argumentList();
                    if (isSymbol(".") || isSymbol("[")) {
                        fail("field-on-call", 'The result of ${name}() has no fields',
                            "Only props, sources, loop variables and implicit roots start a path");
                    }
                    return new Expr(Call(name, arguments), at);
                }
                return path(name, at);
            case Symbol("("):
                advance();
                var inner = expression();
                expectSymbol(")", "to close the parenthesis");
                return inner;
            case Symbol("["):
                advance();
                return new Expr(ListLiteral(list()), at);
            case Symbol("{"):
                advance();
                return new Expr(RecordLiteral(record()), at);
            default:
                return fail("expected-expression",
                    'Expected an expression but found ${describe(token)}',
                    isSymbol("=") ? "Use == to compare" : null);
        }
    }

    function path(root:String, at:Position):Expr {
        var segments:Array<PathSegment> = [];
        while (true) {
            if (acceptSymbol(".")) {
                var namePosition = tokenPosition();
                switch current().kind {
                    case Word(name):
                        advance();
                        segments.push(Field(name, namePosition));
                    default:
                        fail("expected-field",
                            'Expected a field name after . but found ${describe(current())}');
                }
            } else if (isSymbol("[")) {
                var indexPosition = tokenPosition();
                advance();
                var key = expression();
                expectSymbol("]", "to close the index");
                segments.push(Index(key, indexPosition));
            } else {
                return new Expr(Path(root, segments), at);
            }
        }
    }

    function argumentList():Array<Argument> {
        expectSymbol("(", "to start the arguments");
        var arguments:Array<Argument> = [];
        if (acceptSymbol(")")) {
            return arguments;
        }
        var named = false;
        while (true) {
            var at = tokenPosition();
            var name = argumentName();
            if (name != null) {
                named = true;
            } else if (named) {
                fail("positional-after-named",
                    "Positional arguments must come before named arguments");
            }
            arguments.push(new Argument(name, expression(), at));
            if (acceptSymbol(")")) {
                return arguments;
            }
            expectSymbol(",", "between arguments");
        }
    }

    /** Consumes `name:` when the current tokens start a named argument. **/
    function argumentName():Null<String> {
        return switch [current().kind, tokens[index + 1].kind] {
            case [Word(name), Symbol(":")]:
                advance();
                advance();
                name;
            default:
                null;
        }
    }

    function list():Array<Expr> {
        var items:Array<Expr> = [];
        if (acceptSymbol("]")) {
            return items;
        }
        while (true) {
            items.push(expression());
            if (acceptSymbol("]")) {
                return items;
            }
            expectSymbol(",", "between list entries");
        }
    }

    function record():Array<RecordEntry> {
        var entries:Array<RecordEntry> = [];
        var names:Map<String, Bool> = [];
        if (acceptSymbol("}")) {
            return entries;
        }
        while (true) {
            var at = tokenPosition();
            var name = switch current().kind {
                case Word(name):
                    advance();
                    name;
                default:
                    fail("expected-key", 'Expected a key but found ${describe(current())}');
            }
            if (names.exists(name)) {
                failAt("duplicate-key", 'The key ${name} is repeated', at);
            }
            names.set(name, true);
            expectSymbol(":", "after the key");
            entries.push(new RecordEntry(name, expression(), at));
            if (acceptSymbol("}")) {
                return entries;
            }
            expectSymbol(",", "between record entries");
        }
    }

    function loop():LoopSyntax {
        var at = tokenPosition();
        var variable = switch current().kind {
            case Word(name) if (!keywords.exists(name)):
                advance();
                name;
            default:
                fail("invalid-for", 'Expected a loop variable but found ${describe(current())}',
                    loopHint);
        }
        if (!isWord("in")) {
            fail("invalid-for", 'Expected in after ${variable} but found ${describe(current())}',
                loopHint);
        }
        advance();
        var list = expression();
        expectEnd();
        return new LoopSyntax(variable, at, list);
    }

    function type():TypeSyntax {
        var at = tokenPosition();
        var name = switch current().kind {
            case Word(name) if (!keywords.exists(name)):
                advance();
                name;
            default:
                fail("expected-type", 'Expected a type but found ${describe(current())}');
        }
        var parameters:Array<TypeSyntax> = [];
        if (acceptSymbol("<")) {
            parameters.push(type());
            while (acceptSymbol(",")) {
                parameters.push(type());
            }
            closeTypeParameters();
        }
        return new TypeSyntax(name, parameters, acceptSymbol("?"), at);
    }

    /** Closes `<…>`; a `>=` written without a space is split into `>` and `=`. **/
    function closeTypeParameters():Void {
        if (isSymbol(">=")) {
            var token = current();
            tokens[index] = new Token(Symbol("="), token.offset + 1, 1);
            return;
        }
        expectSymbol(">", "to close the type parameters");
    }

    function prop():PropSyntax {
        var declared = type();
        var defaultValue = acceptSymbol("=") ? expression() : null;
        expectEnd();
        return new PropSyntax(declared, defaultValue);
    }

    function expectEnd():Void {
        if (current().kind != End) {
            fail("unexpected-token", 'Unexpected ${describe(current())} after the expression',
                isSymbol("=") ? "Use == to compare" : null);
        }
    }

    function expectSymbol(text:String, purpose:String):Void {
        if (!acceptSymbol(text)) {
            fail("expected-token", 'Expected ${text} ${purpose} but found ${describe(current())}');
        }
    }

    function acceptSymbol(text:String):Bool {
        if (isSymbol(text)) {
            advance();
            return true;
        }
        return false;
    }

    function isSymbol(text:String):Bool {
        return switch current().kind {
            case Symbol(found):
                found == text;
            default:
                false;
        }
    }

    function isWord(name:String):Bool {
        return switch current().kind {
            case Word(found):
                found == name;
            default:
                false;
        }
    }

    inline function current():Token {
        return tokens[index];
    }

    function advance():Void {
        if (index < tokens.length - 1) {
            index++;
        }
    }

    function tokenPosition():Position {
        return lexer.position(current().offset);
    }

    static function describe(token:Token):String {
        return switch token.kind {
            case Word(name):
                name;
            case Text(value):
                'the string \'${value}\'';
            case Integer(value):
                'the number ${value}';
            case Decimal(value):
                'the number ${value}';
            case Symbol(text):
                text;
            case End:
                "the end of the expression";
        }
    }

    function fail(code:String, message:String, ?hint:String):Dynamic {
        return failAt(code, message, tokenPosition(), hint);
    }

    function failAt(code:String, message:String, position:Position, ?hint:String):Dynamic {
        diagnostics.push(new Diagnostic(code, message, position, hint));
        throw new ParseFailure();
    }
}
