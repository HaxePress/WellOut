package wellout.render;

import haxe.ds.StringMap;
import wellout.ByteWriter;
import wellout.check.Types;

/** The static kind of a value, which decides how it prints and when it is truthy. */
enum abstract ValueKind(Int) {
    var KString;
    var KInt;
    var KFloat;
    var KBool;
    var KUrl;
    var KSafeHtml;
    var KList;
    var KMap;
    var KOther;
}

/**
    Runtime operations on host values. Records are anonymous objects, class
    instances or string maps; lists are arrays. Reads never copy.
**/
class Values {
    public static function kindOf(type:WellType):ValueKind {
        return switch Types.nonNull(type) {
            case TString: KString;
            case TInt: KInt;
            case TFloat: KFloat;
            case TBool: KBool;
            case TUrl: KUrl;
            case TSafeHtml: KSafeHtml;
            case TList(_): KList;
            case TMap(_): KMap;
            default: KOther;
        }
    }

    public static function field(target:Dynamic, name:String):Dynamic {
        if (Std.isOfType(target, StringMap)) {
            var map:StringMap<Dynamic> = cast target;
            return map.get(name);
        }
        return Reflect.field(target, name);
    }

    public static function truthy(value:Dynamic, kind:ValueKind):Bool {
        if (value == null) {
            return false;
        }
        return switch kind {
            case KBool:
                value == true;
            case KString | KUrl | KSafeHtml:
                Std.isOfType(value, String) ? (value : String).length > 0 : truthyDynamic(value);
            case KInt | KFloat:
                toFloat(value) != 0;
            case KList:
                Std.isOfType(value, Array) ? (value : Array<Dynamic>).length > 0 : true;
            case KMap:
                nonEmptyMap(value);
            case KOther:
                truthyDynamic(value);
        }
    }

    public static function truthyDynamic(value:Dynamic):Bool {
        if (value == null) {
            return false;
        }
        if (Std.isOfType(value, Bool)) {
            return value == true;
        }
        if (Std.isOfType(value, String)) {
            return (value : String).length > 0;
        }
        if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
            return toFloat(value) != 0;
        }
        if (Std.isOfType(value, Array)) {
            return (value : Array<Dynamic>).length > 0;
        }
        return true;
    }

    static function nonEmptyMap(value:Dynamic):Bool {
        if (Std.isOfType(value, StringMap)) {
            var map:StringMap<Dynamic> = cast value;
            return map.keys().hasNext();
        }
        return Reflect.fields(value).length > 0;
    }

    public static function toInt(value:Dynamic):Int {
        if (value == null) {
            return 0;
        }
        if (Std.isOfType(value, Int)) {
            return (value : Int);
        }
        if (Std.isOfType(value, Float)) {
            return Std.int((value : Float));
        }
        if (Std.isOfType(value, String)) {
            var parsed = Std.parseInt(value);
            return parsed == null ? 0 : parsed;
        }
        return value == true ? 1 : 0;
    }

    public static function toFloat(value:Dynamic):Float {
        if (value == null) {
            return 0;
        }
        if (Std.isOfType(value, Int)) {
            return (value : Int);
        }
        if (Std.isOfType(value, Float)) {
            return (value : Float);
        }
        if (Std.isOfType(value, String)) {
            var parsed = Std.parseFloat(value);
            return Math.isNaN(parsed) ? 0 : parsed;
        }
        return value == true ? 1 : 0;
    }

    public static function toText(value:Dynamic):Null<String> {
        if (value == null) {
            return null;
        }
        if (Std.isOfType(value, String)) {
            return value;
        }
        return Std.string(value);
    }

    public static function equals(left:Dynamic, right:Dynamic):Bool {
        if (left == null || right == null) {
            return left == null && right == null;
        }
        var leftNumber = Std.isOfType(left, Int) || Std.isOfType(left, Float);
        var rightNumber = Std.isOfType(right, Int) || Std.isOfType(right, Float);
        if (leftNumber && rightNumber) {
            return toFloat(left) == toFloat(right);
        }
        if (Std.isOfType(left, String) && Std.isOfType(right, String)) {
            return (left : String) == (right : String);
        }
        if (Std.isOfType(left, Bool) && Std.isOfType(right, Bool)) {
            return (left : Bool) == (right : Bool);
        }
        return left == right;
    }

    /** Writes a value in text or attribute context; null writes nothing. **/
    public static function write(value:Dynamic, kind:ValueKind, writer:ByteWriter):Void {
        if (value == null) {
            return;
        }
        switch kind {
            case KString | KUrl:
                if (Std.isOfType(value, String)) {
                    writer.text(value);
                } else {
                    writeDynamic(value, writer);
                }
            case KSafeHtml:
                writer.trusted(Std.isOfType(value, String) ? value : Std.string(value));
            case KInt:
                if (Std.isOfType(value, Int)) {
                    writer.int(value);
                } else {
                    writer.float(toFloat(value));
                }
            case KFloat:
                writer.float(toFloat(value));
            case KBool:
                writer.trusted(value == true ? "true" : "false");
            default:
                writeDynamic(value, writer);
        }
    }

    public static function writeDynamic(value:Dynamic, writer:ByteWriter):Void {
        if (value == null) {
            return;
        }
        if (Std.isOfType(value, String)) {
            writer.text(value);
        } else if (Std.isOfType(value, Bool)) {
            writer.trusted(value == true ? "true" : "false");
        } else if (Std.isOfType(value, Int)) {
            writer.int(value);
        } else if (Std.isOfType(value, Float)) {
            writer.float(value);
        } else {
            writer.text(Std.string(value));
        }
    }
}
