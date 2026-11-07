package wellout.render;

#if php
import php.Global;
import php.NativeAssocArray;
import php.Syntax;
#end
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
        #if php
        // The same escapes in one native pass: indexing PHP strings by character is quadratic.
        writer.byte('"'.code);
        writer.trusted(Syntax.code("strtr({0}, {1})", text, phpEscapes()));
        writer.byte('"'.code);
        #else
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
        #end
    }

    #if php
    static var escapes:Null<NativeAssocArray<String>> = null;

    static function phpEscapes():NativeAssocArray<String> {
        if (escapes == null) {
            var table = new NativeAssocArray<String>();
            table['"'] = '\\"';
            table["\\"] = "\\\\";
            table["\n"] = "\\n";
            table["\r"] = "\\r";
            table["\t"] = "\\t";
            table["<"] = "\\u003c";
            table[">"] = "\\u003e";
            table["&"] = "\\u0026";
            table[String.fromCharCode(0x2028)] = "\\u2028";
            table[String.fromCharCode(0x2029)] = "\\u2029";
            for (code in 0...0x20) {
                var character = String.fromCharCode(code);
                if (!Global.isset(table[character])) {
                    table[character] = controlEscape(code);
                }
            }
            escapes = table;
        }
        return escapes;
    }
    #end

    static function controlEscape(code:Int):String {
        return '\\u00${StringTools.hex(code, 2).toLowerCase()}';
    }
}
