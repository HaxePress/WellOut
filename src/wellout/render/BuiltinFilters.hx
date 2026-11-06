package wellout.render;

import wellout.ByteWriter;

/** The language's built-in filters (SPEC §4.5) with allocation-free writer forms where possible. */
class BuiltinFilters {
    static final color = ~/^#[0-9a-fA-F]{6}$/;
    static final shortColor = ~/^#[0-9a-fA-F]{3}$/;
    static final cssLength = ~/^-?(?:\d+|\d*\.\d+)(?:px|rem|em|%|vh|vw|vmin|vmax|ch|ex|pt)?$/;

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

    public static function validColor(value:Null<String>):Null<String> {
        if (value == null) {
            return null;
        }
        return color.match(value) || shortColor.match(value) ? value : null;
    }

    public static function validLength(value:Null<String>):Null<String> {
        if (value == null) {
            return null;
        }
        return cssLength.match(value) ? value : null;
    }
}
