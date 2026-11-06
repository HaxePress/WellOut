package wellout.render;

import haxe.ds.StringMap;
import wellout.ByteWriter;

/**
    Writes host values as JSON inside a `<script type="application/json">`
    element. `<`, `>`, `&`, U+2028 and U+2029 are escaped (SPEC §8.1), so
    the text can neither close the element nor break a JavaScript parser.
**/
class JsonWriter {
    static inline final MAX_DEPTH = 32;

    public static function write(value:Dynamic, writer:ByteWriter, depth:Int = 0):Void {
        if (depth > MAX_DEPTH || value == null) {
            writer.trusted("null");
            return;
        }
        if (Std.isOfType(value, Bool)) {
            writer.trusted(value == true ? "true" : "false");
        } else if (Std.isOfType(value, Int)) {
            writer.int(value);
        } else if (Std.isOfType(value, Float)) {
            var number:Float = value;
            if (Math.isFinite(number)) {
                writer.float(number);
            } else {
                writer.trusted("null");
            }
        } else if (Std.isOfType(value, String)) {
            string(value, writer);
        } else if (Std.isOfType(value, Array)) {
            var items:Array<Dynamic> = cast value;
            writer.byte("[".code);
            for (index in 0...items.length) {
                if (index > 0) {
                    writer.byte(",".code);
                }
                write(items[index], writer, depth + 1);
            }
            writer.byte("]".code);
        } else if (Std.isOfType(value, StringMap)) {
            var map:StringMap<Dynamic> = cast value;
            writer.byte("{".code);
            var first = true;
            for (key in map.keys()) {
                if (!first) {
                    writer.byte(",".code);
                }
                first = false;
                string(key, writer);
                writer.byte(":".code);
                write(map.get(key), writer, depth + 1);
            }
            writer.byte("}".code);
        } else {
            writer.byte("{".code);
            var first = true;
            for (key in Reflect.fields(value)) {
                if (!first) {
                    writer.byte(",".code);
                }
                first = false;
                string(key, writer);
                writer.byte(":".code);
                write(Reflect.field(value, key), writer, depth + 1);
            }
            writer.byte("}".code);
        }
    }

    public static function string(text:String, writer:ByteWriter):Void {
        writer.byte('"'.code);
        var start = 0;
        for (index in 0...text.length) {
            var code = StringTools.fastCodeAt(text, index);
            var escape = switch code {
                case '"'.code: '\\"';
                case "\\".code: "\\\\";
                case "\n".code: "\\n";
                case "\r".code: "\\r";
                case "\t".code: "\\t";
                case "<".code: "\\u003c";
                case ">".code: "\\u003e";
                case "&".code: "\\u0026";
                case 0x2028: "\\u2028";
                case 0x2029: "\\u2029";
                default: code < 0x20 ? controlEscape(code) : null;
            }
            if (escape != null) {
                if (index > start) {
                    writer.trustedRange(text, start, index);
                }
                writer.trusted(escape);
                start = index + 1;
            }
        }
        if (text.length > start) {
            writer.trustedRange(text, start, text.length);
        }
        writer.byte('"'.code);
    }

    static function controlEscape(code:Int):String {
        return '\\u00${StringTools.hex(code, 2).toLowerCase()}';
    }
}
