package wellout.render;

import haxe.io.Bytes;
import wellout.ByteWriter;
import wellout.check.CheckedTemplate.AssetKind;
import wellout.render.Eval;
import wellout.render.Values;

/** A compiled template node. Ops are immutable after compilation and shared between renders. */
abstract class Op {
    public abstract function render(context:RenderContext):Void;
}

class EmptyOp extends Op {
    public function new() {}

    public function render(context:RenderContext):Void {}
}

/** Pre-encoded static markup. */
class ChunkOp extends Op {
    public final bytes:Bytes;

    public function new(bytes:Bytes) {
        this.bytes = bytes;
    }

    public function render(context:RenderContext):Void {
        context.out.chunk(bytes);
    }
}

class SequenceOp extends Op {
    final ops:Array<Op>;

    public function new(ops:Array<Op>) {
        this.ops = ops;
    }

    public function render(context:RenderContext):Void {
        for (index in 0...ops.length) {
            ops[index].render(context);
        }
    }
}

/** An interpolated value in text or inside a quoted attribute value. */
class PrintOp extends Op {
    final value:Eval;

    public function new(value:Eval) {
        this.value = value;
    }

    public function render(context:RenderContext):Void {
        value.write(context, context.out);
    }
}

class BranchOp extends Op {
    final conditions:Array<Eval>;
    final bodies:Array<Op>;
    final otherwise:Null<Op>;

    public function new(conditions:Array<Eval>, bodies:Array<Op>, otherwise:Null<Op>) {
        this.conditions = conditions;
        this.bodies = bodies;
        this.otherwise = otherwise;
    }

    public function render(context:RenderContext):Void {
        for (index in 0...conditions.length) {
            if (conditions[index].bool(context)) {
                bodies[index].render(context);
                return;
            }
        }
        if (otherwise != null) {
            otherwise.render(context);
        }
    }
}

class RepeatOp extends Op {
    final list:Eval;
    final slot:Int;
    final loop:Int;
    final body:Op;
    final empty:Null<Op>;

    public function new(list:Eval, slot:Int, loop:Int, body:Op, empty:Null<Op>) {
        this.list = list;
        this.slot = slot;
        this.loop = loop;
        this.body = body;
        this.empty = empty;
    }

    public function render(context:RenderContext):Void {
        var value = list.value(context);
        var items:Null<Array<Dynamic>> = value != null && Std.isOfType(value, Array) ? value : null;
        if (items == null || items.length == 0) {
            if (empty != null) {
                empty.render(context);
            }
            return;
        }
        var position = context.intBase + loop * 2;
        var count = items.length;
        for (index in 0...count) {
            context.ints[position] = index;
            context.ints[position + 1] = count;
            context.setSlot(slot, items[index]);
            body.render(context);
            context.checkOutput();
        }
        context.setSlot(slot, null);
    }
}

/** ` name="value"` for a bound value; a null value omits the attribute. */
class BoundAttributeOp extends Op {
    final prefix:Bytes;
    final value:Eval;

    public function new(prefix:Bytes, value:Eval) {
        this.prefix = prefix;
        this.value = value;
    }

    public function render(context:RenderContext):Void {
        var result = value.value(context);
        if (result == null) {
            return;
        }
        var out = context.out;
        out.chunk(prefix);
        Values.write(result, value.kind, out);
        out.byte('"'.code);
    }
}

/** A boolean attribute such as ` disabled`, written when its value is truthy. */
class BooleanAttributeOp extends Op {
    final markup:Bytes;
    final value:Eval;

    public function new(markup:Bytes, value:Eval) {
        this.markup = markup;
        this.value = value;
    }

    public function render(context:RenderContext):Void {
        if (value.bool(context)) {
            context.out.chunk(markup);
        }
    }
}

/** One part of a URL attribute: static text or a value. */
class UrlPart {
    public final literal:Null<String>;
    public final encoded:Null<Bytes>;
    public final value:Null<Eval>;

    public function new(literal:Null<String>, value:Null<Eval>) {
        this.literal = literal;
        this.value = value;
        encoded = literal == null ? null : Bytes.ofString(literal);
    }
}

/**
    A URL attribute (SPEC §8.2). A static start that decides the scheme is
    classified at compile time; otherwise the value is checked when it is
    written. Site-relative URLs pass through the host's link mapper when a
    render has one.
**/
class UrlAttributeOp extends Op {
    final prefix:Bytes;
    final parts:Array<UrlPart>;

    /** Omit the attribute when a bound value is null. **/
    final omitNull:Bool;

    final staticClass:Int;

    public function new(prefix:Bytes, parts:Array<UrlPart>, omitNull:Bool) {
        this.prefix = prefix;
        this.parts = parts;
        this.omitNull = omitNull;
        var first = parts.length > 0 ? parts[0] : null;
        staticClass = first == null ? Urls.SAFE : first.literal == null ? -1 : Urls.classifyPrefix(StringTools.htmlUnescape(first.literal),
            parts.length == 1);
    }

    public function render(context:RenderContext):Void {
        var out = context.out;
        if (staticClass >= 0) {
            if (staticClass == Urls.UNDECIDED
                || (staticClass == Urls.SITE && context.linkMapper != null)) {
                composed(context);
                return;
            }
            out.chunk(prefix);
            if (staticClass != Urls.UNSAFE) {
                writeParts(context, 0);
            }
            out.byte('"'.code);
            return;
        }
        var lead = Values.toText(parts[0].value.value(context));
        if (lead == null && omitNull) {
            return;
        }
        var text = lead == null ? "" : lead;
        var classification = Urls.classifyPrefix(text, parts.length == 1);
        if (classification == Urls.UNDECIDED
            || (classification == Urls.SITE && context.linkMapper != null)) {
            composed(context);
            return;
        }
        out.chunk(prefix);
        if (classification != Urls.UNSAFE) {
            out.text(text);
            writeParts(context, 1);
        }
        out.byte('"'.code);
    }

    function writeParts(context:RenderContext, from:Int):Void {
        var out = context.out;
        for (index in from...parts.length) {
            var part = parts[index];
            if (part.encoded != null) {
                out.chunk(part.encoded);
            } else {
                part.value.write(context, out);
            }
        }
    }

    /** Builds the whole URL when the scheme is still open or a link mapper applies. **/
    function composed(context:RenderContext):Void {
        var text = new StringBuf();
        for (part in parts) {
            if (part.literal != null) {
                text.add(StringTools.htmlUnescape(part.literal));
            } else {
                var value = Values.toText(part.value.value(context));
                if (value != null) {
                    text.add(value);
                }
            }
        }
        var url = text.toString();
        var classification = Urls.classify(url);
        var out = context.out;
        out.chunk(prefix);
        if (classification == Urls.SITE && context.linkMapper != null) {
            out.text(context.linkMapper(url));
        } else if (classification != Urls.UNSAFE) {
            out.text(url);
        }
        out.byte('"'.code);
    }
}

/** `srcset`: every candidate URL is checked (SPEC §8.1). */
class SrcsetAttributeOp extends Op {
    final prefix:Bytes;
    final value:Eval;

    public function new(prefix:Bytes, value:Eval) {
        this.prefix = prefix;
        this.value = value;
    }

    public function render(context:RenderContext):Void {
        var text = Values.toText(value.value(context));
        if (text == null) {
            return;
        }
        var out = context.out;
        out.chunk(prefix);
        var first = true;
        for (candidate in text.split(",")) {
            var trimmed = StringTools.trim(candidate);
            if (trimmed == "") {
                continue;
            }
            var space = trimmed.indexOf(" ");
            var url = space < 0 ? trimmed : trimmed.substr(0, space);
            var classification = Urls.classify(url);
            if (classification == Urls.UNSAFE) {
                continue;
            }
            if (!first) {
                out.trusted(", ");
            }
            first = false;
            if (classification == Urls.SITE && context.linkMapper != null) {
                var url = context.linkMapper(space < 0 ? trimmed : trimmed.substr(0, space));
                out.text(space < 0 ? url : url + trimmed.substr(space));
            } else {
                out.text(trimmed);
            }
        }
        out.byte('"'.code);
    }
}

/** The class list of an element: static parts, a bound string or list, and forwarded classes. */
class ClassAttributeOp extends Op {
    static final prefix = Bytes.ofString(' class="');

    final parts:Null<Op>;
    final bound:Null<Eval>;
    final forwards:Bool;

    public function new(parts:Null<Op>, bound:Null<Eval>, forwards:Bool) {
        this.parts = parts;
        this.bound = bound;
        this.forwards = forwards;
    }

    public function render(context:RenderContext):Void {
        var out = context.out;
        var start = out.length;
        out.chunk(prefix);
        var contentStart = out.length;
        writeEntries(context, contentStart);
        if (forwards && context.invocation >= 0) {
            var site = context.sites[context.invocation];
            if (site.forwardedClass != null) {
                var savedInvocation = context.invocation;
                var savedValueBase = context.valueBase;
                var savedIntBase = context.intBase;
                context.valueBase = context.callerValueBases[savedInvocation];
                context.intBase = context.callerIntBases[savedInvocation];
                context.invocation = context.callerInvocations[savedInvocation];
                site.forwardedClass.writeEntries(context, contentStart);
                context.valueBase = savedValueBase;
                context.intBase = savedIntBase;
                context.invocation = savedInvocation;
            }
        }
        if (out.length == contentStart) {
            out.rewind(start);
        } else {
            out.byte('"'.code);
        }
    }

    public function writeEntries(context:RenderContext, contentStart:Int):Void {
        var out = context.out;
        if (parts != null) {
            if (out.length > contentStart) {
                out.byte(" ".code);
            }
            var before = out.length;
            parts.render(context);
            if (out.length == before && before > contentStart) {
                out.rewind(before - 1);
            }
        }
        if (bound == null) {
            return;
        }
        if (Std.isOfType(bound, ListEval)) {
            var literal:ListEval = cast bound;
            for (item in literal.items) {
                entry(Values.toText(item.value(context)), out, contentStart);
            }
            return;
        }
        var value = bound.value(context);
        if (value == null) {
            return;
        }
        if (Std.isOfType(value, Array)) {
            var items:Array<Dynamic> = cast value;
            for (item in items) {
                entry(Values.toText(item), out, contentStart);
            }
        } else {
            entry(Values.toText(value), out, contentStart);
        }
    }

    static function entry(text:Null<String>, out:ByteWriter, contentStart:Int):Void {
        if (text == null || text.length == 0) {
            return;
        }
        if (out.length > contentStart) {
            out.byte(" ".code);
        }
        out.text(text);
    }
}

/** The caller's forwarded attributes at a component's `:attrs` element (SPEC §5.2). */
class ForwardedAttributesOp extends Op {
    public function new() {}

    public function render(context:RenderContext):Void {
        var current = context.invocation;
        if (current < 0) {
            return;
        }
        var site = context.sites[current];
        if (site.forwarded == null) {
            return;
        }
        var savedValueBase = context.valueBase;
        var savedIntBase = context.intBase;
        context.valueBase = context.callerValueBases[current];
        context.intBase = context.callerIntBases[current];
        context.invocation = context.callerInvocations[current];
        site.forwarded.render(context);
        context.valueBase = savedValueBase;
        context.intBase = savedIntBase;
        context.invocation = current;
    }
}

/** Records where a fragment's markup starts and ends (SPEC §9.1). */
class FragmentOp extends Op {
    final name:String;
    final body:Op;

    public function new(name:String, body:Op) {
        this.name = name;
        this.body = body;
    }

    public function render(context:RenderContext):Void {
        var tracked = context.fragment == name && context.fragmentStart < 0
            && context.out == context.main;
        var start = context.out.length;
        body.render(context);
        if (tracked) {
            context.fragmentStart = start;
            context.fragmentEnd = context.out.length;
        }
    }
}

/** Marks that the page needs the client runtime, for swaps (SPEC §9.2). */
class RuntimeMarkOp extends Op {
    public function new() {}

    public function render(context:RenderContext):Void {
        context.needsRuntime = true;
    }
}

/** The CSRF field of a post form and the method override of put, patch and delete (§8.5). */
class FormTokenOp extends Op {
    static final open = Bytes.ofString('<input type="hidden" name="_token" value="');
    static final close = Bytes.ofString('">');

    final spoofedMethod:Null<String>;
    final method:Null<Bytes>;

    public function new(spoofedMethod:Null<String>) {
        this.spoofedMethod = spoofedMethod;
        method = spoofedMethod == null ? null : Bytes.ofString('<input type="hidden" name="_method" value="${spoofedMethod}">');
    }

    public function render(context:RenderContext):Void {
        var out = context.out;
        out.chunk(open);
        out.text(context.host.csrfToken());
        out.chunk(close);
        if (method != null) {
            out.chunk(method);
        }
    }
}

/** A call of a component: props, forwarded attributes and slot contents. */
class ComponentOp extends Op {
    public var template:CompiledTemplate;

    final propSlots:Array<Int>;
    final propValues:Array<Eval>;
    final defaultSlots:Array<Int>;
    final defaultValues:Array<Eval>;

    public final forwardedClass:Null<ClassAttributeOp>;
    public final forwarded:Null<Op>;
    public final slotNames:Array<String>;
    public final slotBodies:Array<Op>;
    public final slotLets:Array<Int>;

    public function new(template:CompiledTemplate, propSlots:Array<Int>, propValues:Array<Eval>,
            defaultSlots:Array<Int>, defaultValues:Array<Eval>,
            forwardedClass:Null<ClassAttributeOp>, forwarded:Null<Op>, slotNames:Array<String>,
            slotBodies:Array<Op>, slotLets:Array<Int>) {
        this.template = template;
        this.propSlots = propSlots;
        this.propValues = propValues;
        this.defaultSlots = defaultSlots;
        this.defaultValues = defaultValues;
        this.forwardedClass = forwardedClass;
        this.forwarded = forwarded;
        this.slotNames = slotNames;
        this.slotBodies = slotBodies;
        this.slotLets = slotLets;
    }

    public function slotIndex(name:String):Int {
        for (index in 0...slotNames.length) {
            if (slotNames[index] == name) {
                return index;
            }
        }
        return -1;
    }

    public function render(context:RenderContext):Void {
        var callee = template;
        context.reserveFrame(callee.valueSlots, callee.intSlots);
        var base = context.valueTop;
        var intBase = context.intTop;
        for (index in 0...propSlots.length) {
            context.values[base + propSlots[index]] = propValues[index].value(context);
        }
        var invocation = context.pushInvocation(this);
        var savedValueBase = context.valueBase;
        var savedIntBase = context.intBase;
        var savedValueTop = context.valueTop;
        var savedIntTop = context.intTop;
        var savedInvocation = context.invocation;
        context.valueBase = base;
        context.intBase = intBase;
        context.valueTop = base + callee.valueSlots;
        context.intTop = intBase + callee.intSlots;
        context.invocation = invocation;
        for (index in 0...defaultSlots.length) {
            context.values[base + defaultSlots[index]] = defaultValues[index].value(context);
        }
        callee.loadSources(context);
        callee.body.render(context);
        for (index in base...base + callee.valueSlots) {
            context.values[index] = null;
        }
        context.valueBase = savedValueBase;
        context.intBase = savedIntBase;
        context.valueTop = savedValueTop;
        context.intTop = savedIntTop;
        context.invocation = savedInvocation;
        context.invocationTop--;
    }
}

/** A `<slot>`: the caller's content in the caller's frame, or the fallback. */
class SlotOutletOp extends Op {
    final name:String;
    final exposes:Null<Eval>;
    final fallback:Op;

    public function new(name:String, exposes:Null<Eval>, fallback:Op) {
        this.name = name;
        this.exposes = exposes;
        this.fallback = fallback;
    }

    public function render(context:RenderContext):Void {
        var current = context.invocation;
        if (current < 0) {
            fallback.render(context);
            return;
        }
        var site = context.sites[current];
        var index = site.slotIndex(name);
        if (index < 0) {
            fallback.render(context);
            return;
        }
        var letSlot = site.slotLets[index];
        var exposed:Dynamic = exposes == null || letSlot < 0 ? null : exposes.value(context);
        var savedValueBase = context.valueBase;
        var savedIntBase = context.intBase;
        context.valueBase = context.callerValueBases[current];
        context.intBase = context.callerIntBases[current];
        context.invocation = context.callerInvocations[current];
        if (letSlot >= 0) {
            context.setSlot(letSlot, exposed);
        }
        site.slotBodies[index].render(context);
        context.valueBase = savedValueBase;
        context.intBase = savedIntBase;
        context.invocation = current;
    }
}

/** `<well:head>` content, collected and written at `<HeadOutlet />` (SPEC §5.7). */
class HeadOp extends Op {
    final body:Op;

    public function new(body:Op) {
        this.body = body;
    }

    public function render(context:RenderContext):Void {
        if (context.fragment != null) {
            return;
        }
        var saved = context.out;
        context.out = context.head;
        body.render(context);
        context.out = saved;
    }
}

/** A `<title>` inside `<well:head>`: the one closest to the page template wins. */
class TitleOp extends Op {
    final body:Op;

    public function new(body:Op) {
        this.body = body;
    }

    public function render(context:RenderContext):Void {
        var depth = context.depth;
        if (depth >= context.titleDepth) {
            return;
        }
        context.titleDepth = depth;
        context.title.reset();
        var saved = context.out;
        context.out = context.title;
        body.render(context);
        context.out = saved;
    }
}

class HeadOutletOp extends Op {
    public function new() {}

    public function render(context:RenderContext):Void {
        if (context.out == context.main) {
            context.headMark = context.main.length;
        }
    }
}

class AssetsOp extends Op {
    public function new() {}

    public function render(context:RenderContext):Void {
        if (context.out == context.main) {
            context.assetsMark = context.main.length;
        }
    }
}

class AssetOp extends Op {
    final kind:AssetKind;
    final path:String;

    public function new(kind:AssetKind, path:String) {
        this.kind = kind;
        this.path = path;
    }

    public function render(context:RenderContext):Void {
        context.addAsset(kind, path);
    }
}

/** A client island: fallback markup followed by its props and messages as JSON (§9.3). */
class IslandOp extends Op {
    static final moduleOpen = Bytes.ofString('" data-module="');
    static final close = Bytes.ofString('">');
    static final propsOpen = Bytes.ofString('<script type="application/json" data-well-props nonce="');
    static final propsEnd = Bytes.ofString('</script></well-island>');

    final name:String;
    final load:String;
    final open:Bytes;
    final props:Null<Eval>;
    final fallback:Op;
    final translationKeys:Array<String>;

    public function new(name:String, load:String, props:Null<Eval>, fallback:Op,
            translationKeys:Array<String>) {
        this.name = name;
        this.load = load;
        open = Bytes.ofString('<well-island data-name="${name}" data-load="${load}');
        this.props = props;
        this.fallback = fallback;
        this.translationKeys = translationKeys;
    }

    public function render(context:RenderContext):Void {
        context.needsRuntime = true;
        var out = context.out;
        out.chunk(open);
        out.chunk(moduleOpen);
        out.text(context.host.islandModule(name));
        out.chunk(close);
        fallback.render(context);
        out.chunk(propsOpen);
        out.text(context.host.nonce());
        out.chunk(close);
        out.trusted('{"props":');
        JsonWriter.write(props == null ? null : props.value(context), out);
        out.trusted(',"messages":{');
        for (index in 0...translationKeys.length) {
            if (index > 0) {
                out.byte(",".code);
            }
            var key = translationKeys[index];
            JsonWriter.string(key, out);
            out.byte(":".code);
            JsonWriter.string(context.host.translate(key), out);
        }
        out.trusted("}}");
        out.chunk(propsEnd);
    }
}
