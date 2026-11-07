package wellout.render;

import haxe.Exception;
import haxe.io.Bytes;
import wellout.check.CheckedTemplate.AssetKind;
import wellout.render.CompiledTemplate.CompiledProp;
import wellout.render.Eval;
import wellout.render.Ops;
import wellout.render.Values.ValueKind;
#if php
import php.Global;
import php.Lib;
#end

/** A stored image that does not describe a template this version can restore. */
class TemplateImageError extends Exception {}

/**
    A compiled template as plain data, for hosts that keep compiled
    templates between processes. PHP, for example, starts the application
    for every request; it stores images with `var_export` and loads them
    with opcache instead of parsing, checking and compiling templates again.

    An image holds only strings, integers, floats, booleans, null and
    arrays. It describes the operation tree that the compiler produced from
    a checked template, so restoring it renders byte for byte the same
    output through the same renderer: escaping, URL checks and budgets are
    unchanged, and nothing in an image is ever evaluated as code. Helpers,
    filters, sources and components are named and resolved again through
    the set when the image is decoded. Hosts key stored images by the
    sources and the compiler version they were compiled from (`VERSION`).
**/
@:access(wellout.render)
class TemplateImage {
    /** The image format; images of another format are not restored. **/
    public static inline final VERSION = 2;

    public static function encode(template:CompiledTemplate):Array<Dynamic> {
        return [
            VERSION,
            template.name,
            template.valueSlots,
            template.loopParents.copy(),
            [
                for (prop in template.props) [prop.name, prop.slot, nullableEval(prop.defaultValue)]
            ],
            [
                for (source in template.sources) [source.slot, source.name, arguments(source.arguments)]
            ],
            op(template.body),
            template.fragments.copy()
        ];
    }

    /**
        Rebuilds the template of `image` in `set`, which resolves its
        helpers, filters, sources and components. Throws `TemplateImageError`
        when the image does not match this format or this set.
    **/
    public static function decode(image:Dynamic, set:TemplateSet):CompiledTemplate {
        var reader = new ImageReader(set);
        var fields = reader.list(image, 8);
        if (reader.int(fields[0]) != VERSION) {
            throw new TemplateImageError("The template image has another format version.");
        }
        var template = new CompiledTemplate(reader.string(fields[1]), null, set.rootNames);
        var loopParents = [for (parent in reader.array(fields[3])) reader.int(parent)];
        template.restoreLayout(reader.int(fields[2]), loopParents);
        var props = [
            for (entry in reader.array(fields[4])) {
                var prop = reader.list(entry, 3);
                new CompiledProp(reader.string(prop[0]), reader.int(prop[1]),
                    reader.nullableEval(prop[2]));
            }
        ];
        var sources = [
            for (entry in reader.array(fields[5])) {
                var source = reader.list(entry, 3);
                var name = reader.string(source[1]);
                var load = set.runtime.source(name);
                if (load == null) {
                    throw new TemplateImageError('The host has no source ${name}.');
                }
                new SourceEval(reader.int(source[0]), name, load, reader.arguments(source[2]));
            }
        ];
        var body = reader.op(fields[6]);
        var fragments = [for (name in reader.array(fields[7])) reader.string(name)];
        template.finish(props, sources, body, fragments);
        return template;
    }

    static inline function text(bytes:Bytes):String {
        return bytes.toString();
    }

    static function nullableOp(value:Null<Op>):Dynamic {
        return value == null ? null : op(value);
    }

    static function nullableEval(value:Null<Eval>):Dynamic {
        return value == null ? null : eval(value);
    }

    static function arguments(value:CallArguments):Array<Dynamic> {
        return [
            [for (parameter in value.parameters) nullableEval(parameter)],
            value.extraNames.copy(),
            [for (extra in value.extras) eval(extra)]
        ];
    }

    static function op(value:Op):Array<Dynamic> {
        if (Std.isOfType(value, ChunkOp)) {
            var chunk:ChunkOp = cast value;
            return [OpTag.CHUNK, text(chunk.bytes)];
        }
        if (Std.isOfType(value, SequenceOp)) {
            var sequence:SequenceOp = cast value;
            return [OpTag.SEQUENCE, [for (item in sequence.ops) op(item)]];
        }
        if (Std.isOfType(value, PrintOp)) {
            var print:PrintOp = cast value;
            return [OpTag.PRINT, eval(print.value), print.raw];
        }
        if (Std.isOfType(value, BranchOp)) {
            var branch:BranchOp = cast value;
            return [
                OpTag.BRANCH,
                [for (condition in branch.conditions) eval(condition)],
                [for (body in branch.bodies) op(body)],
                nullableOp(branch.otherwise)
            ];
        }
        if (Std.isOfType(value, RepeatOp)) {
            var repeat:RepeatOp = cast value;
            return [
                OpTag.REPEAT,
                eval(repeat.list),
                repeat.slot,
                repeat.loop,
                op(repeat.body),
                nullableOp(repeat.empty)
            ];
        }
        if (Std.isOfType(value, BoundAttributeOp)) {
            var attribute:BoundAttributeOp = cast value;
            return [OpTag.BOUND_ATTRIBUTE, text(attribute.prefix), eval(attribute.value)];
        }
        if (Std.isOfType(value, BooleanAttributeOp)) {
            var attribute:BooleanAttributeOp = cast value;
            return [OpTag.BOOLEAN_ATTRIBUTE, text(attribute.markup), eval(attribute.value)];
        }
        if (Std.isOfType(value, UrlAttributeOp)) {
            var attribute:UrlAttributeOp = cast value;
            return [
                OpTag.URL_ATTRIBUTE,
                text(attribute.prefix),
                [for (part in attribute.parts) [part.literal, nullableEval(part.value)]],
                attribute.omitNull
            ];
        }
        if (Std.isOfType(value, SrcsetAttributeOp)) {
            var attribute:SrcsetAttributeOp = cast value;
            return [OpTag.SRCSET_ATTRIBUTE, text(attribute.prefix), eval(attribute.value)];
        }
        if (Std.isOfType(value, ClassAttributeOp)) {
            var attribute:ClassAttributeOp = cast value;
            return [
                OpTag.CLASS_ATTRIBUTE,
                nullableOp(attribute.parts),
                nullableEval(attribute.bound),
                attribute.forwards
            ];
        }
        if (Std.isOfType(value, FragmentOp)) {
            var fragment:FragmentOp = cast value;
            return [OpTag.FRAGMENT, fragment.name, op(fragment.body)];
        }
        if (Std.isOfType(value, FormTokenOp)) {
            var form:FormTokenOp = cast value;
            return [OpTag.FORM_TOKEN, form.spoofedMethod];
        }
        if (Std.isOfType(value, ComponentOp)) {
            var component:ComponentOp = cast value;
            return [
                OpTag.COMPONENT,
                component.template.name,
                component.propSlots.copy(),
                [for (item in component.propValues) eval(item)],
                component.defaultSlots.copy(),
                [for (item in component.defaultValues) eval(item)],
                nullableOp(component.forwardedClass),
                nullableOp(component.forwarded),
                component.slotNames.copy(),
                [for (body in component.slotBodies) op(body)],
                component.slotLets.copy()
            ];
        }
        if (Std.isOfType(value, SlotOutletOp)) {
            var outlet:SlotOutletOp = cast value;
            return [
                OpTag.SLOT_OUTLET,
                outlet.name,
                nullableEval(outlet.exposes),
                op(outlet.fallback)
            ];
        }
        if (Std.isOfType(value, HeadOp)) {
            var head:HeadOp = cast value;
            return [OpTag.HEAD, op(head.body)];
        }
        if (Std.isOfType(value, TitleOp)) {
            var title:TitleOp = cast value;
            return [OpTag.TITLE, op(title.body)];
        }
        if (Std.isOfType(value, AssetOp)) {
            var asset:AssetOp = cast value;
            return [OpTag.ASSET, asset.kind == Css ? "css" : "js", asset.path];
        }
        if (Std.isOfType(value, IslandOp)) {
            var island:IslandOp = cast value;
            return [
                OpTag.ISLAND,
                island.name,
                island.load,
                nullableEval(island.props),
                op(island.fallback),
                island.translationKeys.copy()
            ];
        }
        if (Std.isOfType(value, EmptyOp)) {
            return [OpTag.EMPTY];
        }
        if (Std.isOfType(value, ForwardedAttributesOp)) {
            return [OpTag.FORWARDED_ATTRIBUTES];
        }
        if (Std.isOfType(value, RuntimeMarkOp)) {
            return [OpTag.RUNTIME_MARK];
        }
        if (Std.isOfType(value, HeadOutletOp)) {
            return [OpTag.HEAD_OUTLET];
        }
        if (Std.isOfType(value, AssetsOp)) {
            return [OpTag.ASSETS];
        }
        throw new TemplateImageError('The operation ${Type.getClassName(Type.getClass(value))} has no image.');
    }

    static function eval(value:Eval):Array<Dynamic> {
        var kind:Int = cast value.kind;
        if (Std.isOfType(value, ConstEval)) {
            var constant:ConstEval = cast value;
            var encoded = constant.encoded == null ? null : text(constant.encoded);
            return [EvalTag.CONST, constant.constant, kind, encoded];
        }
        if (Std.isOfType(value, SlotEval)) {
            var slot:SlotEval = cast value;
            return [EvalTag.SLOT, slot.index, kind];
        }
        if (Std.isOfType(value, RootEval)) {
            var root:RootEval = cast value;
            return [EvalTag.ROOT, root.index, kind];
        }
        if (Std.isOfType(value, FieldEval)) {
            var field:FieldEval = cast value;
            return [EvalTag.FIELD, eval(field.target), field.name, kind];
        }
        if (Std.isOfType(value, IndexEval)) {
            var index:IndexEval = cast value;
            return [EvalTag.INDEX, eval(index.target), eval(index.key), index.isMap, kind];
        }
        if (Std.isOfType(value, LoopFieldEval)) {
            var loop:LoopFieldEval = cast value;
            return [EvalTag.LOOP_FIELD, loop.loop, loop.field];
        }
        if (Std.isOfType(value, HelperEval)) {
            var helper:HelperEval = cast value;
            return [EvalTag.HELPER, helper.name, arguments(helper.arguments), kind];
        }
        if (Std.isOfType(value, FilterEval)) {
            var filter:FilterEval = cast value;
            return [
                EvalTag.FILTER,
                eval(filter.target),
                filter.name,
                arguments(filter.arguments),
                filter.skipsNull,
                kind
            ];
        }
        if (Std.isOfType(value, ListEval)) {
            var list:ListEval = cast value;
            return [EvalTag.LIST, [for (item in list.items) eval(item)]];
        }
        if (Std.isOfType(value, RecordEval)) {
            var record:RecordEval = cast value;
            return
                [EvalTag.RECORD, record.names.copy(), [for (entry in record.entries) eval(entry)]];
        }
        if (Std.isOfType(value, NotEval)) {
            var not:NotEval = cast value;
            return [EvalTag.NOT, eval(not.operand)];
        }
        if (Std.isOfType(value, NegateEval)) {
            var negate:NegateEval = cast value;
            return [EvalTag.NEGATE, eval(negate.operand), kind];
        }
        if (Std.isOfType(value, LogicEval)) {
            var logic:LogicEval = cast value;
            return [EvalTag.LOGIC, eval(logic.left), eval(logic.right), logic.conjunction];
        }
        if (Std.isOfType(value, CoalesceEval)) {
            var coalesce:CoalesceEval = cast value;
            return [EvalTag.COALESCE, eval(coalesce.left), eval(coalesce.right), kind];
        }
        if (Std.isOfType(value, ArithmeticEval)) {
            var arithmetic:ArithmeticEval = cast value;
            return [
                EvalTag.ARITHMETIC,
                arithmetic.operation,
                eval(arithmetic.left),
                eval(arithmetic.right),
                kind
            ];
        }
        if (Std.isOfType(value, CompareEval)) {
            var compare:CompareEval = cast value;
            return [
                EvalTag.COMPARE,
                compare.operation,
                eval(compare.left),
                eval(compare.right),
                compare.numeric
            ];
        }
        if (Std.isOfType(value, InEval)) {
            var membership:InEval = cast value;
            return [EvalTag.IN, eval(membership.item), eval(membership.list)];
        }
        if (Std.isOfType(value, ChoiceEval)) {
            var choice:ChoiceEval = cast value;
            return [
                EvalTag.CHOICE,
                eval(choice.condition),
                eval(choice.consequent),
                nullableEval(choice.alternative),
                kind
            ];
        }
        if (Std.isOfType(value, ConcatEval)) {
            var concat:ConcatEval = cast value;
            return [
                EvalTag.CONCAT,
                concat.literals.copy(),
                [for (part in concat.values) nullableEval(part)]
            ];
        }
        throw new TemplateImageError('The expression ${Type.getClassName(Type.getClass(value))} has no image.');
    }
}

private enum abstract OpTag(Int) from Int to Int {
    var EMPTY = 0;
    var CHUNK = 1;
    var SEQUENCE = 2;
    var PRINT = 3;
    var BRANCH = 4;
    var REPEAT = 5;
    var BOUND_ATTRIBUTE = 6;
    var BOOLEAN_ATTRIBUTE = 7;
    var URL_ATTRIBUTE = 8;
    var SRCSET_ATTRIBUTE = 9;
    var CLASS_ATTRIBUTE = 10;
    var FORWARDED_ATTRIBUTES = 11;
    var FRAGMENT = 12;
    var RUNTIME_MARK = 13;
    var FORM_TOKEN = 14;
    var COMPONENT = 15;
    var SLOT_OUTLET = 16;
    var HEAD = 17;
    var TITLE = 18;
    var HEAD_OUTLET = 19;
    var ASSETS = 20;
    var ASSET = 21;
    var ISLAND = 22;
}

private enum abstract EvalTag(Int) from Int to Int {
    var CONST = 0;
    var SLOT = 1;
    var ROOT = 2;
    var FIELD = 3;
    var INDEX = 4;
    var LOOP_FIELD = 5;
    var HELPER = 6;
    var FILTER = 7;
    var LIST = 8;
    var RECORD = 9;
    var NOT = 10;
    var NEGATE = 11;
    var LOGIC = 12;
    var COALESCE = 13;
    var ARITHMETIC = 14;
    var COMPARE = 15;
    var IN = 16;
    var CHOICE = 17;
    var CONCAT = 18;
}

/** Reads an image with a check of every value it uses. */
@:access(wellout.render)
private class ImageReader {
    final set:TemplateSet;

    public function new(set:TemplateSet) {
        this.set = set;
    }

    public function array(value:Dynamic):Array<Dynamic> {
        #if php
        // Images loaded from PHP files hold native arrays; wrapping one does not copy it.
        if (Global.is_array(value)) {
            return Lib.toHaxeArray(value);
        }
        #end
        if (value == null || !Std.isOfType(value, Array)) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return cast value;
    }

    public function list(value:Dynamic, length:Int):Array<Dynamic> {
        var items = array(value);
        if (items.length != length) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return items;
    }

    public function int(value:Dynamic):Int {
        #if php
        if (Global.is_int(value)) {
            return value;
        }
        #end
        if (!Std.isOfType(value, Int)) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return cast value;
    }

    public function bool(value:Dynamic):Bool {
        if (!Std.isOfType(value, Bool)) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return cast value;
    }

    public function string(value:Dynamic):String {
        #if php
        if (Global.is_string(value)) {
            return value;
        }
        #end
        if (!Std.isOfType(value, String)) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return cast value;
    }

    public function nullableString(value:Dynamic):Null<String> {
        return value == null ? null : string(value);
    }

    public function kind(value:Dynamic):ValueKind {
        var number = int(value);
        if (number < 0 || number > (cast ValueKind.KOther : Int)) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return cast number;
    }

    public function bytes(value:Dynamic):Bytes {
        return Bytes.ofString(string(value));
    }

    /** A constant of a `ConstEval`: text, a number, a boolean or null. **/
    public function constant(value:Dynamic):Dynamic {
        if (value == null
            || Std.isOfType(value, String)
            || Std.isOfType(value, Float)
            || Std.isOfType(value, Bool)) {
            return value;
        }
        throw new TemplateImageError("The template image is malformed.");
    }

    public function nullableOp(value:Dynamic):Null<Op> {
        return value == null ? null : op(value);
    }

    public function nullableEval(value:Dynamic):Null<Eval> {
        return value == null ? null : eval(value);
    }

    public function arguments(value:Dynamic):CallArguments {
        var fields = list(value, 3);
        return new CallArguments([for (parameter in array(fields[0])) nullableEval(parameter)],
            [for (name in array(fields[1])) string(name)],
            [for (extra in array(fields[2])) eval(extra)]);
    }

    public function op(value:Dynamic):Op {
        var fields = array(value);
        if (fields.length == 0) {
            throw new TemplateImageError("The template image is malformed.");
        }
        var tag:OpTag = int(fields[0]);
        return switch tag {
            case OpTag.EMPTY:
                new EmptyOp();
            case OpTag.CHUNK:
                new ChunkOp(bytes(list(value, 2)[1]));
            case OpTag.SEQUENCE:
                new SequenceOp([for (item in array(list(value, 2)[1])) op(item)]);
            case OpTag.PRINT:
                var parts = list(value, 3);
                new PrintOp(eval(parts[1]), bool(parts[2]));
            case OpTag.BRANCH:
                var parts = list(value, 4);
                var conditions = [for (condition in array(parts[1])) eval(condition)];
                var bodies = [for (body in array(parts[2])) op(body)];
                if (conditions.length != bodies.length) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new BranchOp(conditions, bodies, nullableOp(parts[3]));
            case OpTag.REPEAT:
                var parts = list(value, 6);
                new RepeatOp(eval(parts[1]), int(parts[2]), int(parts[3]), op(parts[4]),
                    nullableOp(parts[5]));
            case OpTag.BOUND_ATTRIBUTE:
                var parts = list(value, 3);
                new BoundAttributeOp(bytes(parts[1]), eval(parts[2]));
            case OpTag.BOOLEAN_ATTRIBUTE:
                var parts = list(value, 3);
                new BooleanAttributeOp(bytes(parts[1]), eval(parts[2]));
            case OpTag.URL_ATTRIBUTE:
                var parts = list(value, 4);
                var urlParts = [
                    for (entry in array(parts[2])) {
                        var part = list(entry, 2);
                        var literal = nullableString(part[0]);
                        var bound = nullableEval(part[1]);
                        if ((literal == null) == (bound == null)) {
                            throw new TemplateImageError("The template image is malformed.");
                        }
                        new UrlPart(literal, bound);
                    }
                ];
                new UrlAttributeOp(bytes(parts[1]), urlParts, bool(parts[3]));
            case OpTag.SRCSET_ATTRIBUTE:
                var parts = list(value, 3);
                new SrcsetAttributeOp(bytes(parts[1]), eval(parts[2]));
            case OpTag.CLASS_ATTRIBUTE:
                classAttribute(value);
            case OpTag.FORWARDED_ATTRIBUTES:
                new ForwardedAttributesOp();
            case OpTag.FRAGMENT:
                var parts = list(value, 3);
                new FragmentOp(string(parts[1]), op(parts[2]));
            case OpTag.RUNTIME_MARK:
                new RuntimeMarkOp();
            case OpTag.FORM_TOKEN:
                var method = nullableString(list(value, 2)[1]);
                if (method != null && method != "PUT" && method != "PATCH" && method != "DELETE") {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new FormTokenOp(method);
            case OpTag.COMPONENT:
                component(value);
            case OpTag.SLOT_OUTLET:
                var parts = list(value, 4);
                new SlotOutletOp(string(parts[1]), nullableEval(parts[2]), op(parts[3]));
            case OpTag.HEAD:
                new HeadOp(op(list(value, 2)[1]));
            case OpTag.TITLE:
                new TitleOp(op(list(value, 2)[1]));
            case OpTag.HEAD_OUTLET:
                new HeadOutletOp();
            case OpTag.ASSETS:
                new AssetsOp();
            case OpTag.ASSET:
                var parts = list(value, 3);
                var kind = switch string(parts[1]) {
                    case "css": Css;
                    case "js": Js;
                    default: throw new TemplateImageError("The template image is malformed.");
                }
                new AssetOp(kind, string(parts[2]));
            case OpTag.ISLAND:
                var parts = list(value, 6);
                new IslandOp(string(parts[1]), string(parts[2]), nullableEval(parts[3]),
                    op(parts[4]), [for (key in array(parts[5])) string(key)]);
            default:
                throw new TemplateImageError('The template image has an unknown operation ${(tag : Int)}.');
        }
    }

    function classAttribute(value:Dynamic):ClassAttributeOp {
        var parts = list(value, 4);
        if (int(parts[0]) != OpTag.CLASS_ATTRIBUTE) {
            throw new TemplateImageError("The template image is malformed.");
        }
        return new ClassAttributeOp(nullableOp(parts[1]), nullableEval(parts[2]), bool(parts[3]));
    }

    function component(value:Dynamic):ComponentOp {
        var parts = list(value, 11);
        var name = string(parts[1]);
        var callee = set.template(name).value;
        if (callee == null) {
            throw new TemplateImageError('The component ${name} could not be restored.');
        }
        var propSlots = [for (slot in array(parts[2])) int(slot)];
        var propValues = [for (item in array(parts[3])) eval(item)];
        var defaultSlots = [for (slot in array(parts[4])) int(slot)];
        var defaultValues = [for (item in array(parts[5])) eval(item)];
        var slotNames = [for (slot in array(parts[8])) string(slot)];
        var slotBodies = [for (body in array(parts[9])) op(body)];
        var slotLets = [for (slot in array(parts[10])) int(slot)];
        if (propSlots.length != propValues.length
            || defaultSlots.length != defaultValues.length
            || slotNames.length != slotBodies.length
            || slotNames.length != slotLets.length) {
            throw new TemplateImageError("The template image is malformed.");
        }
        for (slot in propSlots.concat(defaultSlots)) {
            if (slot < 0 || slot >= callee.valueSlots) {
                throw new TemplateImageError('The component ${name} has another frame layout.');
            }
        }
        var forwardedClass = parts[6] == null ? null : classAttribute(parts[6]);
        return new ComponentOp(callee, propSlots, propValues, defaultSlots, defaultValues,
            forwardedClass, nullableOp(parts[7]), slotNames, slotBodies, slotLets);
    }

    public function eval(value:Dynamic):Eval {
        var fields = array(value);
        if (fields.length == 0) {
            throw new TemplateImageError("The template image is malformed.");
        }
        var tag:EvalTag = int(fields[0]);
        return switch tag {
            case EvalTag.CONST:
                var parts = list(value, 4);
                var literal = constant(parts[1]);
                var written = nullableString(parts[3]);
                if ((literal == null) != (written == null)) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new ConstEval(literal, kind(parts[2]),
                    written == null ? null : Bytes.ofString(written));
            case EvalTag.SLOT:
                var parts = list(value, 3);
                new SlotEval(int(parts[1]), kind(parts[2]));
            case EvalTag.ROOT:
                var parts = list(value, 3);
                var index = int(parts[1]);
                if (index < 0 || index >= set.rootNames.length) {
                    throw new TemplateImageError("The template image names an unknown root.");
                }
                new RootEval(index, kind(parts[2]));
            case EvalTag.FIELD:
                var parts = list(value, 4);
                new FieldEval(eval(parts[1]), string(parts[2]), kind(parts[3]));
            case EvalTag.INDEX:
                var parts = list(value, 5);
                new IndexEval(eval(parts[1]), eval(parts[2]), bool(parts[3]), kind(parts[4]));
            case EvalTag.LOOP_FIELD:
                var parts = list(value, 3);
                var field = int(parts[2]);
                if (field < LoopFieldEval.INDEX || field > LoopFieldEval.LENGTH) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new LoopFieldEval(int(parts[1]), field);
            case EvalTag.HELPER:
                var parts = list(value, 4);
                var name = string(parts[1]);
                var implementation = set.runtime.helper(name);
                if (implementation == null) {
                    throw new TemplateImageError('The host has no helper ${name}.');
                }
                new HelperEval(name, implementation, arguments(parts[2]), kind(parts[3]));
            case EvalTag.FILTER:
                var parts = list(value, 6);
                var name = string(parts[2]);
                var implementation = set.runtime.filter(name);
                if (implementation == null) {
                    throw new TemplateImageError('The host has no filter ${name}.');
                }
                new FilterEval(eval(parts[1]), name, implementation, arguments(parts[3]),
                    bool(parts[4]), kind(parts[5]));
            case EvalTag.LIST:
                new ListEval([for (item in array(list(value, 2)[1])) eval(item)]);
            case EvalTag.RECORD:
                var parts = list(value, 3);
                var names = [for (name in array(parts[1])) string(name)];
                var entries = [for (entry in array(parts[2])) eval(entry)];
                if (names.length != entries.length) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new RecordEval(names, entries);
            case EvalTag.NOT:
                new NotEval(eval(list(value, 2)[1]));
            case EvalTag.NEGATE:
                var parts = list(value, 3);
                new NegateEval(eval(parts[1]), kind(parts[2]));
            case EvalTag.LOGIC:
                var parts = list(value, 4);
                new LogicEval(eval(parts[1]), eval(parts[2]), bool(parts[3]));
            case EvalTag.COALESCE:
                var parts = list(value, 4);
                new CoalesceEval(eval(parts[1]), eval(parts[2]), kind(parts[3]));
            case EvalTag.ARITHMETIC:
                var parts = list(value, 5);
                var operation = int(parts[1]);
                if (operation < ArithmeticEval.ADD || operation > ArithmeticEval.MODULO) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new ArithmeticEval(operation, eval(parts[2]), eval(parts[3]), kind(parts[4]));
            case EvalTag.COMPARE:
                var parts = list(value, 5);
                var operation = int(parts[1]);
                if (operation < CompareEval.EQUAL || operation > CompareEval.GREATER_OR_EQUAL) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                new CompareEval(operation, eval(parts[2]), eval(parts[3]), bool(parts[4]));
            case EvalTag.IN:
                var parts = list(value, 3);
                new InEval(eval(parts[1]), eval(parts[2]));
            case EvalTag.CHOICE:
                var parts = list(value, 5);
                new ChoiceEval(eval(parts[1]), eval(parts[2]), nullableEval(parts[3]),
                    kind(parts[4]));
            case EvalTag.CONCAT:
                var parts = list(value, 3);
                var literals = [for (literal in array(parts[1])) nullableString(literal)];
                var values = [for (part in array(parts[2])) nullableEval(part)];
                if (literals.length != values.length) {
                    throw new TemplateImageError("The template image is malformed.");
                }
                for (index in 0...literals.length) {
                    if ((literals[index] == null) == (values[index] == null)) {
                        throw new TemplateImageError("The template image is malformed.");
                    }
                }
                new ConcatEval(literals, values);
            default:
                throw new TemplateImageError('The template image has an unknown expression ${(tag : Int)}.');
        }
    }
}
