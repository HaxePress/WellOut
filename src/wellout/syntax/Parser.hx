package wellout.syntax;

import wellout.syntax.Ast;

using StringTools;

/** One parsed template with every problem found while reading it. */
class ParseResult {
    public final document:Document;
    public final diagnostics:Array<Diagnostic>;

    public function new(document:Document, diagnostics:Array<Diagnostic>) {
        this.document = document;
        this.diagnostics = diagnostics;
    }

    public function hasErrors():Bool {
        for (diagnostic in diagnostics) {
            if (diagnostic.isError()) {
                return true;
            }
        }
        return false;
    }
}

/**
    Reads the strict HTML subset of Wellout templates (SPEC §3).

    The parser keeps expressions as source text with their positions; a later
    pass parses and type-checks them. It reports structural problems here,
    such as unclosed elements or a misplaced `:else`, and keeps reading so one
    run reports as many problems as it can.
**/
class Parser {
    static final voidElements:Map<String, Bool> = [
        for (name in [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
            "track", "wbr"
        ])
            name => true
    ];
    static final rawTextElements:Map<String, Bool> = ["script" => true, "style" => true];
    static final directives:Map<String, DirectiveKind> = [
        ":if" => If,
        ":else-if" => ElseIf,
        ":else" => Else,
        ":for" => For,
        ":empty" => Empty,
        ":let" => Let,
        ":attrs" => Attrs,
        ":verbatim" => Verbatim
    ];
    static final loopPattern = ~/^\s*[A-Za-z_][A-Za-z0-9_]*\s+in\s+\S/;
    static final eventPattern = ~/^on[a-z]/;

    final source:String;
    final length:Int;
    final lineStarts:Array<Int> = [0];
    final diagnostics:Array<Diagnostic> = [];
    final openElements:Array<String> = [];
    var index = 0;
    var svgDepth = 0;

    public static function parse(source:String):ParseResult {
        var parser = new Parser(source);
        var document = parser.parseDocument();
        return new ParseResult(document, parser.diagnostics);
    }

    function new(source:String) {
        this.source = source;
        length = source.length;
        for (offset in 0...length) {
            if (code(offset) == "\n".code) {
                lineStarts.push(offset + 1);
            }
        }
    }

    function parseDocument():Document {
        var nodes = parseNodes(false);
        var props:Array<Declaration> = [];
        var sources:Array<Declaration> = [];
        var children:Array<Node> = [];
        var leading = true;
        for (node in nodes) {
            switch node {
                case Element(element)
                    if (element.kind == PropsDeclaration || element.kind == SourcesDeclaration):
                    if (!leading) {
                        error("misplaced-declaration",
                            '<${element.name}> must come before the markup',
                            element.position.offset);
                    }
                    var target = element.kind == PropsDeclaration ? props : sources;
                    for (declaration in declarationsOf(element)) {
                        target.push(declaration);
                    }
                case Text(text) if (leading && text.isWhitespace()):
                    // Whitespace around declarations is not part of the output.
                default:
                    leading = false;
                    children.push(node);
            }
        }
        return new Document(props, sources, children);
    }

    function declarationsOf(element:ElementNode):Array<Declaration> {
        var declarations:Array<Declaration> = [];
        if (!element.selfClosing) {
            error("invalid-declaration", '<${element.name}> takes attributes only',
                element.position.offset,
                'Write each entry as an attribute, for example <${element.name} post="ContentSummary" />');
            return declarations;
        }
        for (attribute in element.attributes) {
            switch attribute.kind {
                case StaticValue([Literal(value)]):
                    declarations.push(new Declaration(attribute.name, value.trim(),
                        attribute.position, attribute.valuePosition));
                default:
                    error("invalid-declaration",
                        '<${element.name}> entry "${attribute.name}" needs a plain quoted value',
                        attribute.position.offset);
            }
        }
        return declarations;
    }

    function parseNodes(verbatim:Bool):Array<Node> {
        var nodes:Array<Node> = [];
        while (index < length) {
            if (startsWith("<!--")) {
                skipComment();
                continue;
            }
            if (isClosingTagStart(index)) {
                if (openElements.length > 0) {
                    break;
                }
                var start = index;
                var name = skipClosingTag();
                error("unexpected-closing-tag", 'Closing tag </${name}> has no matching open tag',
                    start);
                continue;
            }
            if (isDoctypeStart(index)) {
                nodes.push(parseDoctype());
                continue;
            }
            if (isOpenTagStart(index)) {
                nodes.push(Element(parseElement(verbatim)));
                continue;
            }
            nodes.push(Text(parseText(verbatim)));
        }
        validateSiblings(nodes);
        return nodes;
    }

    function parseElement(verbatim:Bool):ElementNode {
        var start = index;
        index++;
        var name = readName();
        var kind = kindOf(name);
        var startTag = parseAttributes(name, kind, verbatim);
        var attributes = startTag.attributes;
        if (kind == PropsDeclaration || kind == SourcesDeclaration) {
            if (openElements.length > 0) {
                error("misplaced-declaration", '<${name}> must be at the top of the template',
                    start);
            }
        }
        if (kind == VoidElement) {
            return new ElementNode(name, kind, attributes, [], position(start),
                startTag.selfClosing);
        }
        if (startTag.selfClosing) {
            var allowed = kind != HtmlElement
                && kind != RawTextElement
                || svgDepth > 0
                || name == "svg";
            if (!allowed) {
                error("self-closing-html", '<${name} /> is not a closed element in HTML', start,
                    'Write <${name}></${name}>');
            }
            return new ElementNode(name, kind, attributes, [], position(start), true);
        }
        if (kind == RawTextElement) {
            return new ElementNode(name, kind, attributes, parseRawText(name, start),
                position(start), false);
        }
        var contentVerbatim = verbatim || hasDirective(attributes, Verbatim);
        openElements.push(name);
        if (name == "svg") {
            svgDepth++;
        }
        var children:Array<Node> = [];
        while (true) {
            for (child in parseNodes(contentVerbatim)) {
                children.push(child);
            }
            if (index >= length) {
                error("unclosed-element", 'Element <${name}> is not closed', start,
                    'Add </${name}>');
                break;
            }
            var closingStart = index;
            var closingName = closingTagName(index);
            if (closingName == name) {
                skipClosingTag();
                break;
            }
            if (openElements.lastIndexOf(closingName, openElements.length - 2) >= 0) {
                error("unclosed-element",
                    'Element <${name}> is not closed before </${closingName}>', start,
                    'Add </${name}>');
                break;
            }
            skipClosingTag();
            error("unexpected-closing-tag",
                'Closing tag </${closingName}> does not match the open element <${name}>',
                closingStart);
        }
        if (name == "svg") {
            svgDepth--;
        }
        openElements.pop();
        return new ElementNode(name, kind, attributes, children, position(start), false);
    }

    function parseAttributes(elementName:String, kind:ElementKind,
            verbatim:Bool):{attributes:Array<Attribute>, selfClosing:Bool} {
        var attributes:Array<Attribute> = [];
        var seen:Map<String, Bool> = [];
        var markup = kind == HtmlElement || kind == VoidElement || kind == RawTextElement;
        while (true) {
            skipWhitespace();
            if (index >= length) {
                error("unclosed-start-tag", 'The start tag of <${elementName}> is not closed',
                    index);
                return {attributes: attributes, selfClosing: false};
            }
            if (startsWith("/>")) {
                index += 2;
                return {attributes: attributes, selfClosing: true};
            }
            if (code(index) == ">".code) {
                index++;
                return {attributes: attributes, selfClosing: false};
            }
            var attributeStart = index;
            var name = readAttributeName();
            if (name == "") {
                error("invalid-attribute", 'Unexpected character in <${elementName}>', index);
                index++;
                continue;
            }
            skipWhitespace();
            var hasValue = false;
            var value = "";
            var valueStart = index;
            if (index < length && code(index) == "=".code) {
                index++;
                skipWhitespace();
                hasValue = true;
                valueStart = index;
                var quote = index < length ? code(index) : 0;
                if (quote == '"'.code || quote == "'".code) {
                    var close = source.indexOf(String.fromCharCode(quote), index + 1);
                    if (close < 0) {
                        error("unterminated-attribute", 'The value of ${name} is not closed',
                            index);
                        close = length;
                    }
                    valueStart = index + 1;
                    value = source.substring(valueStart, close);
                    index = close < length ? close + 1 : length;
                } else {
                    error("unquoted-attribute", 'The value of ${name} is not quoted', index,
                        'Write ${name}="…"');
                    while (index < length && !isSpace(code(index)) && code(index) != ">".code) {
                        index++;
                    }
                    value = source.substring(valueStart, index);
                }
            }
            var attribute = attributeOf(name, hasValue, value, valueStart, attributeStart,
                verbatim);
            var key = markup ? attribute.name.toLowerCase() : attribute.name;
            if (key == "class") {
                // A static class and a bound :class combine (SPEC §3.4).
                key = attribute.kind.match(Binding(_, _)) ? "class:bound" : "class:static";
            }
            if (seen.exists(key)) {
                error("duplicate-attribute", 'Attribute ${attribute.name} is set more than once',
                    attributeStart);
            }
            seen.set(key, true);
            if (markup && eventPattern.match(attribute.name.toLowerCase())) {
                error("event-attribute",
                    'Event handler attributes such as ${attribute.name} are not allowed',
                    attributeStart, "Use an island or a server action");
            }
            attributes.push(attribute);
        }
    }

    function attributeOf(name:String, hasValue:Bool, value:String, valueStart:Int,
            attributeStart:Int, verbatim:Bool):Attribute {
        var at = position(attributeStart);
        var valueAt = hasValue ? position(valueStart) : null;
        if (!name.startsWith(":")) {
            if (!hasValue) {
                return new Attribute(name, Present, at);
            }
            var parts = verbatim ? [Literal(value)] : partsOf(valueStart,
                valueStart + value.length);
            return new Attribute(name, StaticValue(parts), at, valueAt);
        }
        var directive = directives.get(name);
        if (directive == null) {
            if (!hasValue || value.trim() == "") {
                error("missing-binding-value", '${name} needs an expression', attributeStart);
            }
            var expression = expressionAt(value, valueStart);
            return new Attribute(name.substr(1), Binding(expression.source, expression.position),
                at, valueAt);
        }
        switch directive {
            case If | ElseIf | For | Let:
                if (!hasValue || value.trim() == "") {
                    error("missing-directive-value", '${name} needs a value', attributeStart);
                }
            case Else | Empty | Attrs | Verbatim:
                if (hasValue) {
                    error("unexpected-directive-value", '${name} takes no value', attributeStart);
                }
        }
        if (directive == For && hasValue && !loopPattern.match(value)) {
            error("invalid-for", ':for needs "name in list"', valueStart,
                'Write :for="item in items"');
        }
        if (!hasValue) {
            return new Attribute(name, Directive(directive, null, null), at);
        }
        var expression = expressionAt(value, valueStart);
        return new Attribute(name, Directive(directive, expression.source, expression.position),
            at, valueAt);
    }

    /** The expression in an attribute value: trimmed, with the position of its first character. **/
    function expressionAt(value:String, valueStart:Int):{source:String, position:Position} {
        var first = 0;
        while (first < value.length && isSpace(StringTools.fastCodeAt(value, first))) {
            first++;
        }
        return {source: value.substr(first).rtrim(), position: position(valueStart + first)};
    }

    /** Text with interpolation between two offsets, used for attribute values. **/
    function partsOf(start:Int, end:Int):Array<TextPart> {
        var parts:Array<TextPart> = [];
        var literalStart = start;
        var offset = start;
        while (offset < end) {
            if (isRawStart(offset, end)) {
                error("raw-in-attribute",
                    "{!! !!} writes HTML and cannot appear in an attribute value", offset,
                    "Use {{ }}, which escapes the value");
                var raw = scanRawInterpolation(offset, end);
                offset = raw.next;
                literalStart = offset;
                continue;
            }
            if (code(offset) == "{".code && offset + 1 < end && code(offset + 1) == "{".code) {
                if (offset > literalStart) {
                    parts.push(Literal(source.substring(literalStart, offset)));
                }
                var interpolation = scanInterpolation(offset, end);
                parts.push(interpolation.part);
                offset = interpolation.next;
                literalStart = offset;
                continue;
            }
            offset++;
        }
        if (end > literalStart) {
            parts.push(Literal(source.substring(literalStart, end)));
        }
        return parts;
    }

    function parseText(verbatim:Bool):TextNode {
        var start = index;
        var parts:Array<TextPart> = [];
        var literalStart = index;
        while (index < length) {
            if (index > start && isMarkupStart(index)) {
                break;
            }
            if (!verbatim && isRawStart(index, length)) {
                if (index > literalStart) {
                    parts.push(Literal(source.substring(literalStart, index)));
                }
                var raw = scanRawInterpolation(index, length);
                parts.push(raw.part);
                index = raw.next;
                literalStart = index;
                continue;
            }
            if (!verbatim
                && code(index) == "{".code
                && index + 1 < length
                && code(index + 1) == "{".code) {
                if (index > literalStart) {
                    parts.push(Literal(source.substring(literalStart, index)));
                }
                var interpolation = scanInterpolation(index, length);
                parts.push(interpolation.part);
                index = interpolation.next;
                literalStart = index;
                continue;
            }
            index++;
        }
        if (index > literalStart) {
            parts.push(Literal(source.substring(literalStart, index)));
        }
        return new TextNode(parts, position(start));
    }

    function isRawStart(offset:Int, end:Int):Bool {
        return offset + 2 < end
            && code(offset) == "{".code
            && code(offset + 1) == "!".code
            && code(offset + 2) == "!".code;
    }

    /** Reads `{!! … !!}` from `start`; quotes inside the expression may contain `!!}`. **/
    function scanRawInterpolation(start:Int, end:Int):{part:TextPart, next:Int} {
        var expressionStart = start + 3;
        var offset = expressionStart;
        var quote = 0;
        while (offset < end) {
            var character = code(offset);
            if (quote != 0) {
                if (character == "\\".code) {
                    offset += 2;
                    continue;
                }
                if (character == quote) {
                    quote = 0;
                }
                offset++;
                continue;
            }
            if (character == "'".code || character == '"'.code) {
                quote = character;
                offset++;
                continue;
            }
            if (character == "!".code
                && offset + 2 < end
                && code(offset + 1) == "!".code
                && code(offset + 2) == "}".code) {
                var expression = interpolationPart(start, expressionStart, offset);
                var part = switch expression {
                    case Interpolation(text, at): RawInterpolation(text, at);
                    default: expression;
                }
                return {part: part, next: offset + 3};
            }
            offset++;
        }
        error("unterminated-interpolation", "The raw interpolation is not closed with !!}", start);
        var unclosed = interpolationPart(start, expressionStart, end);
        var part = switch unclosed {
            case Interpolation(text, at): RawInterpolation(text, at);
            default: unclosed;
        }
        return {part: part, next: end};
    }

    /** Reads `{{ … }}` from `start`; quotes inside the expression may contain `}}`. **/
    function scanInterpolation(start:Int, end:Int):{part:TextPart, next:Int} {
        var expressionStart = start + 2;
        var offset = expressionStart;
        var quote = 0;
        while (offset < end) {
            var character = code(offset);
            if (quote != 0) {
                if (character == "\\".code) {
                    offset += 2;
                    continue;
                }
                if (character == quote) {
                    quote = 0;
                }
                offset++;
                continue;
            }
            if (character == "'".code || character == '"'.code) {
                quote = character;
                offset++;
                continue;
            }
            if (character == "}".code && offset + 1 < end && code(offset + 1) == "}".code) {
                return {part: interpolationPart(start, expressionStart, offset), next: offset + 2};
            }
            offset++;
        }
        error("unterminated-interpolation", "The interpolation is not closed with }}", start);
        return {part: interpolationPart(start, expressionStart, end), next: end};
    }

    function interpolationPart(start:Int, expressionStart:Int, expressionEnd:Int):TextPart {
        var first = expressionStart;
        while (first < expressionEnd && isSpace(code(first))) {
            first++;
        }
        var expression = source.substring(first, expressionEnd).trim();
        if (expression == "") {
            error("empty-interpolation", "The interpolation is empty", start);
        }
        return Interpolation(expression, position(first));
    }

    function parseRawText(name:String, start:Int):Array<Node> {
        var contentStart = index;
        var close = source.toLowerCase().indexOf('</${name}', index);
        if (close < 0) {
            error("unclosed-element", 'Element <${name}> is not closed', start, 'Add </${name}>');
            index = length;
            return contentStart < length ? [
                Text(new TextNode([Literal(source.substring(contentStart, length))],
                    position(contentStart)))
            ] : [];
        }
        index = close;
        skipClosingTag();
        if (close == contentStart) {
            return [];
        }
        return [
            Text(new TextNode([Literal(source.substring(contentStart, close))],
                position(contentStart)))
        ];
    }

    function parseDoctype():Node {
        var start = index;
        var close = source.indexOf(">", index);
        if (close < 0) {
            error("unclosed-doctype", "The doctype is not closed", start);
            close = length - 1;
        }
        index = close + 1;
        return Doctype(source.substring(start, index), position(start));
    }

    function validateSiblings(nodes:Array<Node>):Void {
        var previous:Null<ElementNode> = null;
        for (node in nodes) {
            switch node {
                case Text(text):
                    if (!text.isWhitespace()) {
                        previous = null;
                    }
                case Doctype(_, _):
                    previous = null;
                case Element(element):
                    validateElementDirectives(element, previous);
                    previous = element;
            }
        }
    }

    function validateElementDirectives(element:ElementNode, previous:Null<ElementNode>):Void {
        var conditional = element.directive(If);
        var chained = element.directive(ElseIf) ?? element.directive(Else);
        var loop = element.directive(For);
        var empty = element.directive(Empty);
        var branches = [element.directive(If), element.directive(ElseIf), element.directive(Else)].filter(attribute ->
            attribute != null);
        if (branches.length > 1) {
            error("conflicting-directives",
                'Use one of :if, :else-if and :else on <${element.name}>',
                branches[1].position.offset);
        }
        if (chained != null) {
            var follows = previous != null
                && (previous.directive(If) != null || previous.directive(ElseIf) != null);
            if (!follows) {
                error("misplaced-else",
                    '${chained.name} must follow an element with :if or :else-if',
                    chained.position.offset);
            }
        }
        if (empty != null && (previous == null || previous.directive(For) == null)) {
            error("misplaced-empty", ":empty must follow an element with :for",
                empty.position.offset);
        }
        if (conditional != null && loop != null) {
            error("if-with-for", ":if and :for cannot share an element",
                conditional.position.offset, 'Wrap it in <template :for="…"> and keep :if inside');
        }
    }

    function kindOf(name:String):ElementKind {
        if (name == "props") {
            return PropsDeclaration;
        }
        if (name == "sources") {
            return SourcesDeclaration;
        }
        if (name == "template") {
            return TemplateElement;
        }
        if (name == "slot") {
            return SlotElement;
        }
        var first = name.length == 0 ? 0 : StringTools.fastCodeAt(name, 0);
        if ((first >= "A".code && first <= "Z".code) || name.indexOf(":") > 0) {
            return ComponentElement;
        }
        if (voidElements.exists(name)) {
            return VoidElement;
        }
        if (rawTextElements.exists(name)) {
            return RawTextElement;
        }
        return HtmlElement;
    }

    static function hasDirective(attributes:Array<Attribute>, kind:DirectiveKind):Bool {
        for (attribute in attributes) {
            switch attribute.kind {
                case Directive(found, _, _) if (found == kind):
                    return true;
                default:
            }
        }
        return false;
    }

    function readName():String {
        var start = index;
        while (index < length) {
            var character = code(index);
            var allowed = isLetter(character) || isDigit(character) || character == ":".code
                || character == "-".code || character == "_".code || character == ".".code;
            if (!allowed) {
                break;
            }
            index++;
        }
        return source.substring(start, index);
    }

    function readAttributeName():String {
        var start = index;
        while (index < length) {
            var character = code(index);
            var stop = isSpace(character)
                || character == "=".code
                || character == ">".code
                || character == '"'.code
                || character == "'".code
                || character == "<".code
                || (character == "/".code && index + 1 < length && code(index + 1) == ">".code);
            if (stop) {
                break;
            }
            index++;
        }
        return source.substring(start, index);
    }

    function closingTagName(offset:Int):String {
        var start = offset + 2;
        var end = start;
        while (end < length && !isSpace(code(end)) && code(end) != ">".code) {
            end++;
        }
        return source.substring(start, end);
    }

    function skipClosingTag():String {
        var name = closingTagName(index);
        index += 2 + name.length;
        skipWhitespace();
        if (index < length && code(index) == ">".code) {
            index++;
        } else {
            error("invalid-closing-tag", 'Closing tag </${name}> is not closed with >', index);
        }
        return name;
    }

    function skipComment():Void {
        var start = index;
        var close = source.indexOf("-->", index + 4);
        if (close < 0) {
            error("unclosed-comment", "The comment is not closed with -->", start);
            index = length;
            return;
        }
        index = close + 3;
    }

    function skipWhitespace():Void {
        while (index < length && isSpace(code(index))) {
            index++;
        }
    }

    function isMarkupStart(offset:Int):Bool {
        return isOpenTagStart(offset)
            || isClosingTagStart(offset)
            || isDoctypeStart(offset)
            || source.substr(offset, 4) == "<!--";
    }

    function isOpenTagStart(offset:Int):Bool {
        return code(offset) == "<".code && offset + 1 < length && isLetter(code(offset + 1));
    }

    function isClosingTagStart(offset:Int):Bool {
        return code(offset) == "<".code
            && offset + 2 < length
            && code(offset + 1) == "/".code
            && isLetter(code(offset + 2));
    }

    function isDoctypeStart(offset:Int):Bool {
        return source.substr(offset, 9).toLowerCase() == "<!doctype";
    }

    inline function startsWith(prefix:String):Bool {
        return source.substr(index, prefix.length) == prefix;
    }

    inline function code(offset:Int):Int {
        return offset < length ? StringTools.fastCodeAt(source, offset) : 0;
    }

    static inline function isLetter(character:Int):Bool {
        return (character >= "a".code && character <= "z".code)
            || (character >= "A".code && character <= "Z".code);
    }

    static inline function isDigit(character:Int):Bool {
        return character >= "0".code && character <= "9".code;
    }

    static inline function isSpace(character:Int):Bool {
        return character == " ".code
            || character == "\n".code
            || character == "\t".code
            || character == "\r".code;
    }

    function position(offset:Int):Position {
        var low = 0;
        var high = lineStarts.length - 1;
        while (low < high) {
            var middle = (low + high + 1) >> 1;
            if (lineStarts[middle] <= offset) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        return new Position(offset, low + 1, offset - lineStarts[low] + 1);
    }

    function error(code:String, message:String, offset:Int, ?hint:String):Void {
        diagnostics.push(new Diagnostic(code, message, position(offset), hint));
    }
}
