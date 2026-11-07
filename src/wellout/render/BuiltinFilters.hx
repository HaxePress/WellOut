package wellout.render;

import wellout.ByteWriter;

/**
    The language's built-in filters (SPEC §4.5) with allocation-free writer
    forms where possible. `color` and `length` read characters rather than
    match an EReg: an EReg keeps its match state, so render threads cannot
    share one, and a new EReg allocates a matcher on every call.
**/
class BuiltinFilters {
    static final lengthUnits = ["px", "rem", "em", "%", "vh", "vw", "vmin", "vmax", "ch", "ex", "pt"];

    public static function install(runtime:Runtime):Void {
        runtime.addFilter("truncate", truncate, writeTruncated);
        runtime.addFilter("lower", (input, _, _) -> Values.toText(input).toLowerCase());
        runtime.addFilter("upper", (input, _, _) -> Values.toText(input).toUpperCase());
        runtime.addFilter("default",
            (input, arguments, _) -> isEmpty(input) ? arguments.get(0) : input);
        runtime.addFilter("color", (input, _, _) -> validColor(Values.toText(input)));
        runtime.addFilter("length", (input, _, _) -> validLength(Values.toText(input)));
        runtime.addFilter("number", (input, _, _) -> Values.toText(input), writeNumber);
        runtime.addFilter("date", (input, _, _) -> Values.toText(input));
    }

    static function isEmpty(value:Dynamic):Bool {
        return value == null || (Std.isOfType(value, String) && (value : String).length == 0);
    }

    /** The cut position: at most `length` characters, without splitting a surrogate pair. **/
    static function cut(text:String, length:Int):Int {
        var end = length < 1 ? 1 : length;
        var code = StringTools.fastCodeAt(text, end - 1);
        if (code >= 0xD800 && code <= 0xDBFF) {
            end--;
        }
        while (end > 0 && StringTools.isSpace(text, end - 1)) {
            end--;
        }
        return end;
    }

    static function truncate(input:Dynamic, arguments:Arguments, _:RenderContext):Dynamic {
        var text = Values.toText(input);
        var length = arguments.int(0, 160);
        if (text == null || text.length <= length) {
            return text;
        }
        return text.substr(0, cut(text, length)) + "…";
    }

    static function writeTruncated(input:Dynamic, arguments:Arguments, _:RenderContext,
            writer:ByteWriter):Void {
        var text = Values.toText(input);
        if (text == null) {
            return;
        }
        var length = arguments.int(0, 160);
        if (text.length <= length) {
            writer.text(text);
            return;
        }
        writer.textRange(text, 0, cut(text, length));
        writer.trusted("…");
    }

    static function writeNumber(input:Dynamic, _:Arguments, _:RenderContext,
            writer:ByteWriter):Void {
        if (input == null) {
            return;
        }
        if (Std.isOfType(input, Int)) {
            writer.int(input);
        } else {
            writer.float(Values.toFloat(input));
        }
    }

    /** `value` when it is a `#rgb` or `#rrggbb` color, else null. **/
    public static function validColor(value:Null<String>):Null<String> {
        if (value == null) {
            return null;
        }
        var length = value.length;
        if ((length != 4 && length != 7) || StringTools.fastCodeAt(value, 0) != "#".code) {
            return null;
        }
        for (index in 1...length) {
            if (!isHexDigit(StringTools.fastCodeAt(value, index))) {
                return null;
            }
        }
        return value;
    }

    /** `value` when it is a number with an optional CSS unit, such as `-1.5rem` or `.5em`, else null. **/
    public static function validLength(value:Null<String>):Null<String> {
        if (value == null) {
            return null;
        }
        var length = value.length;
        var start = length > 0 && StringTools.fastCodeAt(value, 0) == "-".code ? 1 : 0;
        var integerEnd = digitsEnd(value, start, length);
        var numberEnd = integerEnd;
        if (integerEnd < length && StringTools.fastCodeAt(value, integerEnd) == ".".code) {
            numberEnd = digitsEnd(value, integerEnd + 1, length);
            if (numberEnd == integerEnd + 1) {
                return null;
            }
        } else if (integerEnd == start) {
            return null;
        }
        return numberEnd == length || hasUnit(value, length - numberEnd) ? value : null;
    }

    static function isHexDigit(code:Int):Bool {
        return (code >= "0".code && code <= "9".code) || (code >= "a".code && code <= "f".code)
            || (code >= "A".code && code <= "F".code);
    }

    /** The index after the ASCII digits that start at `start`. **/
    static function digitsEnd(value:String, start:Int, length:Int):Int {
        var index = start;
        while (index < length) {
            var code = StringTools.fastCodeAt(value, index);
            if (code < "0".code || code > "9".code) {
                break;
            }
            index++;
        }
        return index;
    }

    /** Whether the last `unitLength` characters of `value` are a CSS length unit. **/
    static function hasUnit(value:String, unitLength:Int):Bool {
        for (unit in lengthUnits) {
            if (unit.length == unitLength && StringTools.endsWith(value, unit)) {
                return true;
            }
        }
        return false;
    }
}
