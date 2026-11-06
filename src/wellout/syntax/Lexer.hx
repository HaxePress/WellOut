package wellout.syntax;

/** One expression token with its offset and length in the expression source. */
class Token {
    public final kind:TokenKind;
    public final offset:Int;
    public final length:Int;

    public function new(kind:TokenKind, offset:Int, length:Int) {
        this.kind = kind;
        this.offset = offset;
        this.length = length;
    }
}

enum TokenKind {
    /** An identifier or a keyword. **/
    Word(name:String);

    /** A string literal with its escapes resolved. **/
    Text(value:String);

    Integer(value:Int);
    Decimal(value:Float);

    /** An operator or a punctuation mark. **/
    Symbol(text:String);

    End;
}

/**
    Splits expression source into tokens. The base position of the expression
    maps offsets onto the template, so diagnostics point into the template
    file even when an expression spans several lines.
**/
class Lexer {
    static final symbols = [
        "??", "==", "!=", "<=", ">=", "?", ":", "<", ">", "+", "-", "*", "/", "%", "|", "(", ")",
        "[", "]", "{", "}", ",", ".", "="
    ];
    static final discouraged = ["===", "!==", "&&", "||"];
    static final replacements:Map<String, String> = [
        "===" => "Use == to compare",
        "!==" => "Use != to compare",
        "&&" => "Use 'and' instead of '&&'",
        "||" => "Use 'or' instead of '||'",
        "!" => "Use 'not' instead of '!'"
    ];
    static final escapes:Map<Int, String> = [
        92 => "\\", // backslash
        39 => "'",
        34 => '"',
        110 => "\n", // n
        116 => "\t", // t
        114 => "\r" // r
    ];

    public final diagnostics:Array<Diagnostic> = [];

    final source:String;
    final length:Int;
    final base:Position;
    final lineStarts:Array<Int> = [0];

    public function new(source:String, base:Position) {
        this.source = source;
        this.base = base;
        length = source.length;
        for (offset in 0...length) {
            if (code(offset) == "\n".code) {
                lineStarts.push(offset + 1);
            }
        }
    }

    /** The tokens followed by `End`, or null after a lexical error. */
    public function tokenize():Null<Array<Token>> {
        var tokens:Array<Token> = [];
        var offset = 0;
        while (offset < length) {
            var character = code(offset);
            if (isSpace(character)) {
                offset++;
                continue;
            }
            var token = if (isWordStart(character)) {
                word(offset);
            } else if (isDigit(character)) {
                number(offset);
            } else if (character == "'".code || character == '"'.code) {
                text(offset);
            } else {
                symbol(offset);
            }
            if (token == null) {
                return null;
            }
            tokens.push(token);
            offset += token.length;
        }
        tokens.push(new Token(End, length, 0));
        return tokens;
    }

    /** The template position of an offset in the expression source. */
    public function position(offset:Int):Position {
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
        var column = offset - lineStarts[low];
        if (low == 0) {
            return new Position(base.offset + offset, base.line, base.column + column);
        }
        return new Position(base.offset + offset, base.line + low, column + 1);
    }

    function word(offset:Int):Token {
        var end = offset + 1;
        while (end < length && isWordPart(code(end))) {
            end++;
        }
        return new Token(Word(source.substring(offset, end)), offset, end - offset);
    }

    function number(offset:Int):Null<Token> {
        var end = offset;
        while (end < length && isDigit(code(end))) {
            end++;
        }
        var decimal = false;
        if (end + 1 < length && code(end) == ".".code && isDigit(code(end + 1))) {
            decimal = true;
            end += 2;
            while (end < length && isDigit(code(end))) {
                end++;
            }
        }
        var written = source.substring(offset, end);
        if (end < length && isWordPart(code(end))) {
            error("invalid-number", 'Unexpected letter after the number ${written}', offset,
                "Write values with units as text, such as '12px'");
            return null;
        }
        if (decimal) {
            return new Token(Decimal(Std.parseFloat(written)), offset, end - offset);
        }
        var value = 0.0;
        for (digit in offset...end) {
            value = value * 10 + (code(digit) - "0".code);
        }
        if (value > 2147483647) {
            error("integer-overflow", 'The integer ${written} is larger than 2147483647', offset,
                'Write ${written}.0 for a decimal number');
            return null;
        }
        return new Token(Integer(Std.int(value)), offset, end - offset);
    }

    function text(offset:Int):Null<Token> {
        var quote = code(offset);
        var value = new StringBuf();
        var segmentStart = offset + 1;
        var end = offset + 1;
        while (end < length) {
            var character = code(end);
            if (character == quote) {
                value.add(source.substring(segmentStart, end));
                return new Token(Text(value.toString()), offset, end + 1 - offset);
            }
            if (character == "\\".code) {
                var unicode = unicodeEscape(end);
                if (unicode >= 0) {
                    value.add(source.substring(segmentStart, end));
                    value.addChar(unicode);
                    end += 6;
                    segmentStart = end;
                    continue;
                }
                var escaped = end + 1 < length ? escapes.get(code(end + 1)) : null;
                if (escaped == null) {
                    error("invalid-escape", "Unknown escape sequence", end,
                        "Use \\\\, \\', \\\", \\n, \\t, \\r or \\uXXXX");
                    return null;
                }
                value.add(source.substring(segmentStart, end));
                value.add(escaped);
                end += 2;
                segmentStart = end;
                continue;
            }
            end++;
        }
        error("unterminated-string", "The string is not closed", offset);
        return null;
    }

    /** The code point of a `\\uXXXX` escape at `offset`, or -1. **/
    function unicodeEscape(offset:Int):Int {
        if (offset + 5 >= length || code(offset + 1) != "u".code) {
            return -1;
        }
        var value = 0;
        for (index in offset + 2...offset + 6) {
            var digit = code(index);
            var number = digit >= "0".code
                && digit <= "9".code ? digit - "0".code : digit >= "a".code
                    && digit <= "f".code ? digit - "a".code + 10 : digit >= "A".code
                        && digit <= "F".code ? digit - "A".code + 10 : -1;
            if (number < 0) {
                return -1;
            }
            value = value * 16 + number;
        }
        return value;
    }

    function symbol(offset:Int):Null<Token> {
        for (form in discouraged) {
            if (matches(offset, form)) {
                error("unexpected-character", 'Unexpected ${form}', offset, replacements.get(form));
                return null;
            }
        }
        for (text in symbols) {
            if (matches(offset, text)) {
                return new Token(Symbol(text), offset, text.length);
            }
        }
        if (code(offset) == "!".code) {
            error("unexpected-character", "Unexpected !", offset, replacements.get("!"));
            return null;
        }
        error("unexpected-character", 'Unexpected character ${source.charAt(offset)}', offset);
        return null;
    }

    function error(code:String, message:String, offset:Int, ?hint:String):Void {
        diagnostics.push(new Diagnostic(code, message, position(offset), hint));
    }

    inline function matches(offset:Int, text:String):Bool {
        return source.substr(offset, text.length) == text;
    }

    inline function code(offset:Int):Int {
        return offset < length ? StringTools.fastCodeAt(source, offset) : 0;
    }

    static inline function isWordStart(character:Int):Bool {
        return (character >= "a".code && character <= "z".code)
            || (character >= "A".code && character <= "Z".code)
            || character == "_".code;
    }

    static inline function isWordPart(character:Int):Bool {
        return isWordStart(character) || isDigit(character);
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
}
