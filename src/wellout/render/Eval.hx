package wellout.render;

import haxe.io.Bytes;
import wellout.ByteWriter;
import wellout.render.Runtime;
import wellout.render.Values;

/**
    A compiled expression. Typed reads (`bool`, `int`, `float`) and `write`
    avoid boxing and intermediate strings on the common paths; `value`
    returns the host value as it is.
**/
abstract class Eval {
    public final kind:ValueKind;

    function new(kind:ValueKind) {
        this.kind = kind;
    }

    public abstract function value(context:RenderContext):Dynamic;

    public function bool(context:RenderContext):Bool {
        return Values.truthy(value(context), kind);
    }

    public function int(context:RenderContext):Int {
        return Values.toInt(value(context));
    }

    public function float(context:RenderContext):Float {
        return Values.toFloat(value(context));
    }

    public function write(context:RenderContext, writer:ByteWriter):Void {
        Values.write(value(context), kind, writer);
    }

    /** Whether the value is null, without boxing typed reads. **/
    public function isNull(context:RenderContext):Bool {
        return value(context) == null;
    }
}

class ConstEval extends Eval {
    final constant:Dynamic;
    final encoded:Null<Bytes>;
    final integer:Int;
    final number:Float;
    final flag:Bool;

    public function new(constant:Dynamic, kind:ValueKind) {
        super(kind);
        this.constant = constant;
        integer = constant == null ? 0 : Values.toInt(constant);
        number = constant == null ? 0 : Values.toFloat(constant);
        flag = Values.truthy(constant, kind);
        if (constant != null) {
            var writer = new ByteWriter(64);
            Values.write(constant, kind, writer);
            encoded = writer.toBytes();
        } else {
            encoded = null;
        }
    }

    public function value(context:RenderContext):Dynamic {
        return constant;
    }

    override public function bool(context:RenderContext):Bool {
        return flag;
    }

    override public function int(context:RenderContext):Int {
        return integer;
    }

    override public function float(context:RenderContext):Float {
        return number;
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (encoded != null) {
            writer.chunk(encoded);
        }
    }

    override public function isNull(context:RenderContext):Bool {
        return constant == null;
    }
}

/** A prop, source, loop variable or slot value in the current frame. */
class SlotEval extends Eval {
    final index:Int;

    public function new(index:Int, kind:ValueKind) {
        super(kind);
        this.index = index;
    }

    public function value(context:RenderContext):Dynamic {
        return context.slot(index);
    }
}

class RootEval extends Eval {
    final index:Int;

    public function new(index:Int, kind:ValueKind) {
        super(kind);
        this.index = index;
    }

    public function value(context:RenderContext):Dynamic {
        return context.root(index);
    }
}

class FieldEval extends Eval {
    final target:Eval;
    final name:String;

    public function new(target:Eval, name:String, kind:ValueKind) {
        super(kind);
        this.target = target;
        this.name = name;
    }

    public function value(context:RenderContext):Dynamic {
        var record = target.value(context);
        return record == null ? null : Values.field(record, name);
    }
}

class IndexEval extends Eval {
    final target:Eval;
    final key:Eval;
    final isMap:Bool;

    public function new(target:Eval, key:Eval, isMap:Bool, kind:ValueKind) {
        super(kind);
        this.target = target;
        this.key = key;
        this.isMap = isMap;
    }

    public function value(context:RenderContext):Dynamic {
        var collection = target.value(context);
        if (collection == null) {
            return null;
        }
        if (isMap) {
            var name = Values.toText(key.value(context));
            return name == null ? null : Values.field(collection, name);
        }
        if (!Std.isOfType(collection, Array)) {
            return null;
        }
        var items:Array<Dynamic> = cast collection;
        var position = key.int(context);
        return position >= 0 && position < items.length ? items[position] : null;
    }
}

/** A field of `loop` (SPEC §3.4) for the loop with a static id in the current frame. */
class LoopFieldEval extends Eval {
    public static inline final INDEX = 0;
    public static inline final NUMBER = 1;
    public static inline final FIRST = 2;
    public static inline final LAST = 3;
    public static inline final LENGTH = 4;

    final loop:Int;
    final field:Int;

    public function new(loop:Int, field:Int) {
        super(field == FIRST || field == LAST ? KBool : KInt);
        this.loop = loop;
        this.field = field;
    }

    public function value(context:RenderContext):Dynamic {
        if (loop < 0) {
            return null;
        }
        return kind == KBool ? (bool(context) : Dynamic) : (int(context) : Dynamic);
    }

    override public function int(context:RenderContext):Int {
        if (loop < 0) {
            return 0;
        }
        var index = context.ints[context.intBase + loop * 2];
        var length = context.ints[context.intBase + loop * 2 + 1];
        return switch field {
            case INDEX: index;
            case NUMBER: index + 1;
            case LENGTH: length;
            case FIRST: index == 0 ? 1 : 0;
            default: index == length - 1 ? 1 : 0;
        }
    }

    override public function bool(context:RenderContext):Bool {
        if (loop < 0) {
            return false;
        }
        return field == INDEX ? int(context) != 0 : int(context) != 0;
    }

    override public function float(context:RenderContext):Float {
        return int(context);
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (loop < 0) {
            return;
        }
        if (kind == KBool) {
            writer.trusted(bool(context) ? "true" : "false");
        } else {
            writer.int(int(context));
        }
    }

    override public function isNull(context:RenderContext):Bool {
        return loop < 0;
    }
}

/** Evaluates call arguments into the context's argument stack. */
class CallArguments {
    final parameters:Array<Null<Eval>>;
    final extraNames:Array<String>;
    final extras:Array<Eval>;

    public function new(parameters:Array<Null<Eval>>, extraNames:Array<String>,
            extras:Array<Eval>) {
        this.parameters = parameters;
        this.extraNames = extraNames;
        this.extras = extras;
    }

    /** Evaluates the arguments and returns their base; release it after the call. **/
    public function evaluate(context:RenderContext):Int {
        var count = parameters.length;
        var base = context.reserveArguments(count + extras.length);
        for (index in 0...count) {
            var parameter = parameters[index];
            context.argumentValues[base
                + index] = parameter == null ? null : parameter.value(context);
        }
        for (index in 0...extras.length) {
            context.argumentValues[base + count + index] = extras[index].value(context);
        }
        context.arguments.set(base, count, extraNames);
        return base;
    }
}

class HelperEval extends Eval {
    final implementation:HelperImplementation;
    final arguments:CallArguments;

    public function new(implementation:HelperImplementation, arguments:CallArguments,
            kind:ValueKind) {
        super(kind);
        this.implementation = implementation;
        this.arguments = arguments;
    }

    public function value(context:RenderContext):Dynamic {
        var base = arguments.evaluate(context);
        var result = implementation.call(context.arguments, context);
        context.releaseArguments(base);
        return result;
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (implementation.writer == null) {
            Values.write(value(context), kind, writer);
            return;
        }
        var base = arguments.evaluate(context);
        implementation.writer(context.arguments, context, writer);
        context.releaseArguments(base);
    }
}

class SourceEval {
    public final slot:Int;

    final load:SourceFunction;
    final arguments:CallArguments;

    public function new(slot:Int, load:SourceFunction, arguments:CallArguments) {
        this.slot = slot;
        this.load = load;
        this.arguments = arguments;
    }

    public function resolve(context:RenderContext):Void {
        var base = arguments.evaluate(context);
        var result = load(context.arguments, context);
        context.releaseArguments(base);
        context.setSlot(slot, result);
    }
}

class FilterEval extends Eval {
    final target:Eval;
    final implementation:FilterImplementation;
    final arguments:CallArguments;
    final skipsNull:Bool;

    public function new(target:Eval, implementation:FilterImplementation, arguments:CallArguments,
            skipsNull:Bool, kind:ValueKind) {
        super(kind);
        this.target = target;
        this.implementation = implementation;
        this.arguments = arguments;
        this.skipsNull = skipsNull;
    }

    public function value(context:RenderContext):Dynamic {
        var input = target.value(context);
        if (input == null && skipsNull) {
            return null;
        }
        var base = arguments.evaluate(context);
        var result = implementation.apply(input, context.arguments, context);
        context.releaseArguments(base);
        return result;
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (implementation.writer == null) {
            Values.write(value(context), kind, writer);
            return;
        }
        var input = target.value(context);
        if (input == null && skipsNull) {
            return;
        }
        var base = arguments.evaluate(context);
        implementation.writer(input, context.arguments, context, writer);
        context.releaseArguments(base);
    }
}

class ListEval extends Eval {
    public final items:Array<Eval>;

    public function new(items:Array<Eval>) {
        super(KList);
        this.items = items;
    }

    public function value(context:RenderContext):Dynamic {
        return [for (item in items) item.value(context)];
    }

    override public function bool(context:RenderContext):Bool {
        return items.length > 0;
    }
}

class RecordEval extends Eval {
    final names:Array<String>;
    final entries:Array<Eval>;

    public function new(names:Array<String>, entries:Array<Eval>) {
        super(KOther);
        this.names = names;
        this.entries = entries;
    }

    public function value(context:RenderContext):Dynamic {
        var record:Dynamic = {};
        for (index in 0...names.length) {
            Reflect.setField(record, names[index], entries[index].value(context));
        }
        return record;
    }

    override public function bool(context:RenderContext):Bool {
        return true;
    }
}

class NotEval extends Eval {
    final operand:Eval;

    public function new(operand:Eval) {
        super(KBool);
        this.operand = operand;
    }

    public function value(context:RenderContext):Dynamic {
        return !operand.bool(context);
    }

    override public function bool(context:RenderContext):Bool {
        return !operand.bool(context);
    }
}

class NegateEval extends Eval {
    final operand:Eval;

    public function new(operand:Eval, kind:ValueKind) {
        super(kind);
        this.operand = operand;
    }

    public function value(context:RenderContext):Dynamic {
        return kind == KInt ? (int(context) : Dynamic) : (float(context) : Dynamic);
    }

    override public function int(context:RenderContext):Int {
        return -operand.int(context);
    }

    override public function float(context:RenderContext):Float {
        return -operand.float(context);
    }

    override public function bool(context:RenderContext):Bool {
        return operand.float(context) != 0;
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (kind == KInt) {
            writer.int(int(context));
        } else {
            writer.float(float(context));
        }
    }
}

class LogicEval extends Eval {
    final left:Eval;
    final right:Eval;
    final conjunction:Bool;

    public function new(left:Eval, right:Eval, conjunction:Bool) {
        super(KBool);
        this.left = left;
        this.right = right;
        this.conjunction = conjunction;
    }

    public function value(context:RenderContext):Dynamic {
        return bool(context);
    }

    override public function bool(context:RenderContext):Bool {
        if (conjunction) {
            return left.bool(context) && right.bool(context);
        }
        return left.bool(context) || right.bool(context);
    }
}

class CoalesceEval extends Eval {
    final left:Eval;
    final right:Eval;

    public function new(left:Eval, right:Eval, kind:ValueKind) {
        super(kind);
        this.left = left;
        this.right = right;
    }

    public function value(context:RenderContext):Dynamic {
        var first = left.value(context);
        return first != null ? first : right.value(context);
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (!left.isNull(context)) {
            left.write(context, writer);
        } else {
            right.write(context, writer);
        }
    }
}

class ArithmeticEval extends Eval {
    public static inline final ADD = 0;
    public static inline final SUBTRACT = 1;
    public static inline final MULTIPLY = 2;
    public static inline final DIVIDE = 3;
    public static inline final MODULO = 4;

    final operation:Int;
    final left:Eval;
    final right:Eval;

    public function new(operation:Int, left:Eval, right:Eval, kind:ValueKind) {
        super(kind);
        this.operation = operation;
        this.left = left;
        this.right = right;
    }

    public function value(context:RenderContext):Dynamic {
        return kind == KInt ? (int(context) : Dynamic) : (float(context) : Dynamic);
    }

    override public function int(context:RenderContext):Int {
        if (kind != KInt) {
            return Std.int(float(context));
        }
        var a = left.int(context);
        var b = right.int(context);
        return switch operation {
            case ADD: a + b;
            case SUBTRACT: a - b;
            case MULTIPLY: a * b;
            case MODULO: b == 0 ? 0 : a % b;
            default: b == 0 ? 0 : Std.int(a / b);
        }
    }

    override public function float(context:RenderContext):Float {
        var a = left.float(context);
        var b = right.float(context);
        return switch operation {
            case ADD: a + b;
            case SUBTRACT: a - b;
            case MULTIPLY: a * b;
            case MODULO: b == 0 ? 0 : a % b;
            default: b == 0 ? 0 : a / b;
        }
    }

    override public function bool(context:RenderContext):Bool {
        return float(context) != 0;
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (kind == KInt) {
            writer.int(int(context));
        } else {
            writer.float(float(context));
        }
    }
}

class CompareEval extends Eval {
    public static inline final EQUAL = 0;
    public static inline final NOT_EQUAL = 1;
    public static inline final LESS = 2;
    public static inline final LESS_OR_EQUAL = 3;
    public static inline final GREATER = 4;
    public static inline final GREATER_OR_EQUAL = 5;

    final operation:Int;
    final left:Eval;
    final right:Eval;
    final numeric:Bool;

    public function new(operation:Int, left:Eval, right:Eval, numeric:Bool) {
        super(KBool);
        this.operation = operation;
        this.left = left;
        this.right = right;
        this.numeric = numeric;
    }

    public function value(context:RenderContext):Dynamic {
        return bool(context);
    }

    override public function bool(context:RenderContext):Bool {
        if (operation == EQUAL || operation == NOT_EQUAL) {
            var same = if (numeric && !left.isNull(context) && !right.isNull(context)) {
                left.float(context) == right.float(context);
            } else {
                Values.equals(left.value(context), right.value(context));
            }
            return operation == EQUAL ? same : !same;
        }
        var order = if (numeric) {
            var a = left.float(context);
            var b = right.float(context);
            a < b ? -1 : a > b ? 1 : 0;
        } else {
            var a = Values.toText(left.value(context));
            var b = Values.toText(right.value(context));
            a == null
            || b == null ? 0 : Reflect.compare(a, b);
        }
        return switch operation {
            case LESS: order < 0;
            case LESS_OR_EQUAL: order <= 0;
            case GREATER: order > 0;
            default: order >= 0;
        }
    }
}

class InEval extends Eval {
    final item:Eval;
    final list:Eval;

    public function new(item:Eval, list:Eval) {
        super(KBool);
        this.item = item;
        this.list = list;
    }

    public function value(context:RenderContext):Dynamic {
        return bool(context);
    }

    override public function bool(context:RenderContext):Bool {
        if (Std.isOfType(list, ListEval)) {
            var literal:ListEval = cast list;
            var needle = item.value(context);
            for (entry in literal.items) {
                if (Values.equals(needle, entry.value(context))) {
                    return true;
                }
            }
            return false;
        }
        var collection = list.value(context);
        if (collection == null || !Std.isOfType(collection, Array)) {
            return false;
        }
        var needle = item.value(context);
        var entries:Array<Dynamic> = cast collection;
        for (entry in entries) {
            if (Values.equals(needle, entry)) {
                return true;
            }
        }
        return false;
    }
}

class ChoiceEval extends Eval {
    final condition:Eval;
    final consequent:Eval;
    final alternative:Null<Eval>;

    public function new(condition:Eval, consequent:Eval, alternative:Null<Eval>, kind:ValueKind) {
        super(kind);
        this.condition = condition;
        this.consequent = consequent;
        this.alternative = alternative;
    }

    public function value(context:RenderContext):Dynamic {
        if (condition.bool(context)) {
            return consequent.value(context);
        }
        return alternative == null ? null : alternative.value(context);
    }

    override public function bool(context:RenderContext):Bool {
        if (condition.bool(context)) {
            return consequent.bool(context);
        }
        return alternative != null && alternative.bool(context);
    }

    override public function int(context:RenderContext):Int {
        if (condition.bool(context)) {
            return consequent.int(context);
        }
        return alternative == null ? 0 : alternative.int(context);
    }

    override public function float(context:RenderContext):Float {
        if (condition.bool(context)) {
            return consequent.float(context);
        }
        return alternative == null ? 0 : alternative.float(context);
    }

    override public function write(context:RenderContext, writer:ByteWriter):Void {
        if (condition.bool(context)) {
            consequent.write(context, writer);
        } else if (alternative != null) {
            alternative.write(context, writer);
        }
    }

    override public function isNull(context:RenderContext):Bool {
        if (condition.bool(context)) {
            return consequent.isNull(context);
        }
        return alternative == null || alternative.isNull(context);
    }
}

/** Text composed from parts, used where a whole string is needed, such as a static prop. */
class ConcatEval extends Eval {
    final literals:Array<Null<String>>;
    final values:Array<Null<Eval>>;

    public function new(literals:Array<Null<String>>, values:Array<Null<Eval>>) {
        super(KString);
        this.literals = literals;
        this.values = values;
    }

    public function value(context:RenderContext):Dynamic {
        var text = new StringBuf();
        for (index in 0...literals.length) {
            var literal = literals[index];
            if (literal != null) {
                text.add(literal);
            } else {
                var part = Values.toText(values[index].value(context));
                if (part != null) {
                    text.add(part);
                }
            }
        }
        return text.toString();
    }
}
