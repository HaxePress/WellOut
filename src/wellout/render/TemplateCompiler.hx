package wellout.render;

import haxe.io.Bytes;
import wellout.ByteWriter;
import wellout.check.CheckedTemplate;
import wellout.check.TypedExpr;
import wellout.render.CompiledTemplate;
import wellout.check.Types;
import wellout.render.Eval;
import wellout.render.Ops;
import wellout.render.Values;
import wellout.syntax.Diagnostic;
import wellout.syntax.Position;

using StringTools;

/** Collects ops, merging adjacent static markup into one pre-encoded chunk. */
class SequenceBuilder {
    final ops:Array<Op> = [];
    var text = new StringBuf();
    var pending = false;
    var endsWithNewline = false;

    public function new() {}

    public function literal(markup:String):Void {
        if (markup.length == 0) {
            return;
        }
        text.add(markup);
        pending = true;
        endsWithNewline = StringTools.fastCodeAt(markup, markup.length - 1) == "\n".code;
    }

    /** Collapsed template whitespace: a newline is not repeated within static markup. **/
    public function whitespace(markup:String):Void {
        if (markup == "\n" && pending && endsWithNewline) {
            return;
        }
        literal(markup);
    }

    public function op(op:Op):Void {
        flush();
        ops.push(op);
    }

    function flush():Void {
        if (pending) {
            ops.push(new ChunkOp(Bytes.ofString(text.toString())));
            text = new StringBuf();
            pending = false;
        }
    }

    public function build():Op {
        flush();
        return switch ops.length {
            case 0: new EmptyOp();
            case 1: ops[0];
            default: new SequenceOp(ops);
        }
    }
}

/** Names visible while compiling: frame slots for values and the innermost loop. */
class CompileScope {
    final parent:Null<CompileScope>;
    final slots:Map<String, Int> = [];

    public final loop:Int;

    public function new(?parent:CompileScope, loop:Int = -1) {
        this.parent = parent;
        this.loop = loop;
    }

    public function bind(name:String, slot:Int):Void {
        slots.set(name, slot);
    }

    public function slot(name:String):Int {
        var found = slots.get(name);
        if (found != null) {
            return found;
        }
        return parent == null ? -1 : parent.slot(name);
    }
}

/**
    Compiles a checked template into an op tree for backend B. Components a
    template calls are compiled first through the template set, so a
    component op holds its callee directly.
**/
class TemplateCompiler {
    static final collapsible = ~/[ \t\r]*\n\s*/g;
    static final preserving:Map<String, Bool> = ["pre" => true, "textarea" => true];
    static final spoofed:Map<String, Bool> = ["put" => true, "patch" => true, "delete" => true];

    final set:TemplateSet;
    final runtime:Runtime;
    final template:CompiledTemplate;
    final diagnostics:Array<Diagnostic>;
    final fragments:Array<String> = [];
    var preserveDepth = 0;
    var headDepth = 0;

    public static function compile(checked:CheckedTemplate, set:TemplateSet,
            diagnostics:Array<Diagnostic>):CompiledTemplate {
        var template = new CompiledTemplate(checked.name, checked, set.rootNames);
        var compiler = new TemplateCompiler(set, template, diagnostics);
        compiler.run(checked);
        return template;
    }

    function new(set:TemplateSet, template:CompiledTemplate, diagnostics:Array<Diagnostic>) {
        this.set = set;
        this.runtime = set.runtime;
        this.template = template;
        this.diagnostics = diagnostics;
    }

    function run(checked:CheckedTemplate):Void {
        var scope = new CompileScope();
        var props:Array<CompiledProp> = [];
        for (prop in checked.props) {
            var slot = template.allocateSlot();
            scope.bind(prop.name, slot);
            var defaultValue = prop.defaultValue == null ? null : expression(prop.defaultValue,
                scope);
            props.push(new CompiledProp(prop.name, slot, defaultValue));
        }
        var sources:Array<SourceEval> = [];
        for (source in checked.sources) {
            var slot = template.allocateSlot();
            var compiled = sourceCall(source, slot, scope);
            scope.bind(source.name, slot);
            if (compiled != null) {
                sources.push(compiled);
            }
        }
        var builder = new SequenceBuilder();
        nodes(trimDocument(checked.nodes), scope, builder);
        template.finish(props, sources, builder.build(), fragments);
    }

    /** Drops whitespace-only text at the start and end of a template. **/
    static function trimDocument(list:Array<CheckedNode>):Array<CheckedNode> {
        var start = 0;
        var end = list.length;
        while (start < end && isBlank(list[start])) {
            start++;
        }
        while (end > start && isBlank(list[end - 1])) {
            end--;
        }
        return list.slice(start, end);
    }

    static function isBlank(node:CheckedNode):Bool {
        return switch node {
            case Text(parts):
                for (part in parts) {
                    switch part {
                        case Literal(text) if (text.trim() == ""):
                        default:
                            return false;
                    }
                }
                true;
            default:
                false;
        }
    }

    function sourceCall(source:CheckedSource, slot:Int, scope:CompileScope):Null<SourceEval> {
        switch source.call.kind {
            case SourceCall(signature, arguments):
                var load = runtime.source(signature.name);
                if (load == null) {
                    error("missing-implementation",
                        'The host has no implementation for the source ${signature.name}',
                        source.position);
                    return null;
                }
                return new SourceEval(slot, load,
                    callArguments(signature.parameters, arguments, scope));
            default:
                return null;
        }
    }

    function nodes(list:Array<CheckedNode>, scope:CompileScope, builder:SequenceBuilder):Void {
        for (node in list) {
            this.node(node, scope, builder);
        }
    }

    function node(node:CheckedNode, scope:CompileScope, builder:SequenceBuilder):Void {
        switch node {
            case Text(parts):
                text(parts, scope, builder);
            case Doctype(text):
                builder.literal(text);
            case Element(element):
                this.element(element, scope, builder);
            case Component(component):
                this.component(component, scope, builder);
            case SlotOutlet(outlet):
                var exposes = outlet.exposes == null ? null : expression(outlet.exposes, scope);
                builder.op(new SlotOutletOp(outlet.name, exposes,
                    sequence(outlet.fallback, scope)));
            case Branches(branches):
                this.branches(branches, scope, builder);
            case Repeat(repeat):
                this.repeat(repeat, scope, builder);
            case Group(children):
                nodes(children, scope, builder);
            case Head(children):
                headDepth++;
                builder.op(new HeadOp(sequence(children, scope)));
                headDepth--;
            case HeadOutlet:
                builder.op(new HeadOutletOp());
            case Island(island):
                var props = island.props == null ? null : expression(island.props, scope);
                builder.op(new IslandOp(island.signature.name, island.load, props,
                    sequence(island.fallback, scope), island.signature.translationKeys));
            case Asset(kind, path):
                builder.op(new AssetOp(kind, path));
            case Assets:
                builder.op(new AssetsOp());
        }
    }

    function sequence(list:Array<CheckedNode>, scope:CompileScope):Op {
        var builder = new SequenceBuilder();
        nodes(list, scope, builder);
        return builder.build();
    }

    function text(parts:Array<CheckedPart>, scope:CompileScope, builder:SequenceBuilder):Void {
        for (part in parts) {
            switch part {
                case Literal(text):
                    if (preserveDepth > 0) {
                        builder.literal(text);
                    } else {
                        builder.whitespace(collapsible.replace(text, "\n"));
                    }
                case Print(value):
                    builder.op(new PrintOp(expression(value, scope)));
            }
        }
    }

    function branches(branches:Array<CheckedBranch>, scope:CompileScope,
            builder:SequenceBuilder):Void {
        var conditions:Array<Eval> = [];
        var bodies:Array<Op> = [];
        var otherwise:Null<Op> = null;
        for (branch in branches) {
            var body = sequence([branch.node], scope);
            if (branch.condition == null) {
                otherwise = body;
            } else {
                conditions.push(expression(branch.condition, scope));
                bodies.push(body);
            }
        }
        builder.op(new BranchOp(conditions, bodies, otherwise));
    }

    function repeat(repeat:CheckedRepeat, scope:CompileScope, builder:SequenceBuilder):Void {
        var list = expression(repeat.list, scope);
        var loop = template.allocateLoop(scope.loop);
        var slot = template.allocateSlot();
        var inner = new CompileScope(scope, loop);
        inner.bind(repeat.variable, slot);
        var body = sequence([repeat.body], inner);
        var empty = repeat.empty == null ? null : sequence([repeat.empty], scope);
        builder.op(new RepeatOp(list, slot, loop, body, empty));
    }

    function element(element:CheckedElement, scope:CompileScope, outer:SequenceBuilder):Void {
        var builder = element.fragment == null ? outer : new SequenceBuilder();
        var name = element.name;
        if (headDepth > 0 && name == "title") {
            var title = new SequenceBuilder();
            elementMarkup(element, scope, title);
            outer.op(new TitleOp(title.build()));
            return;
        }
        elementMarkup(element, scope, builder);
        if (element.fragment != null) {
            fragments.push(element.fragment);
            outer.op(new FragmentOp(element.fragment, builder.build()));
        }
    }

    function elementMarkup(element:CheckedElement, scope:CompileScope,
            builder:SequenceBuilder):Void {
        var name = element.name;
        builder.literal('<${name}');
        var spoof:Null<String> = null;
        var tokenized = false;
        var hasClass = false;
        for (attribute in element.attributes) {
            if (name == "form" && attribute.name.toLowerCase() == "method") {
                var method = staticValue(attribute);
                if (method != null) {
                    var lowered = method.toLowerCase();
                    if (lowered == "post" || spoofed.exists(lowered)) {
                        tokenized = true;
                        spoof = spoofed.exists(lowered) ? lowered.toUpperCase() : null;
                        builder.literal(' method="post"');
                        continue;
                    }
                }
            }
            if (attribute.context == ClassList) {
                hasClass = true;
                classAttribute(attribute, element.forwardsAttributes, scope, builder);
                continue;
            }
            if (StringTools.startsWith(attribute.name, "data-well-")) {
                // Runtime behaviours such as data-well-confirm need the client script.
                builder.op(new RuntimeMarkOp());
            }
            this.attribute(attribute, scope, builder);
        }
        if (element.fragment != null) {
            builder.literal(' data-well-fragment="${element.fragment}"');
        }
        if (element.swap != null) {
            builder.op(new RuntimeMarkOp());
            this.attribute(new CheckedAttribute("data-well-swap", element.swap, Plain), scope,
                builder);
        }
        if (element.forwardsAttributes) {
            if (!hasClass) {
                builder.op(new ClassAttributeOp(null, null, true));
            }
            builder.op(new ForwardedAttributesOp());
        }
        builder.literal(">");
        if (tokenized) {
            builder.op(new FormTokenOp(spoof));
        }
        if (element.isVoid) {
            return;
        }
        var preserves = element.isRawText || preserving.exists(name);
        if (preserves) {
            preserveDepth++;
        }
        nodes(element.children, scope, builder);
        if (preserves) {
            preserveDepth--;
        }
        builder.literal('</${name}>');
    }

    static function staticValue(attribute:CheckedAttribute):Null<String> {
        return switch attribute.value {
            case Static([]): "";
            case Static([Literal(text)]): text;
            default: null;
        }
    }

    function classAttribute(attribute:CheckedAttribute, forwards:Bool, scope:CompileScope,
            builder:SequenceBuilder):Void {
        switch attribute.value {
            case Classes(parts, bound):
                var staticOp = parts.length == 0 ? null : attributeParts(parts, scope);
                var boundEval = bound == null ? null : expression(bound, scope);
                if (!forwards && boundEval == null && staticOp != null && isStatic(parts)) {
                    var text = literalText(parts);
                    if (text.trim() != "") {
                        builder.literal(' class="${escapeAttribute(text)}"');
                    }
                    return;
                }
                builder.op(new ClassAttributeOp(staticOp, boundEval, forwards));
            default:
                this.attribute(attribute, scope, builder);
        }
    }

    static function isStatic(parts:Array<CheckedPart>):Bool {
        for (part in parts) {
            if (part.match(Print(_))) {
                return false;
            }
        }
        return true;
    }

    static function literalText(parts:Array<CheckedPart>):String {
        var text = new StringBuf();
        for (part in parts) {
            switch part {
                case Literal(value):
                    text.add(value);
                default:
            }
        }
        return text.toString();
    }

    /** Static attribute text is markup source; only a double quote needs escaping. **/
    static function escapeAttribute(text:String):String {
        return text.replace('"', "&quot;");
    }

    function attributeParts(parts:Array<CheckedPart>, scope:CompileScope):Op {
        var builder = new SequenceBuilder();
        for (part in parts) {
            switch part {
                case Literal(text):
                    builder.literal(escapeAttribute(text));
                case Print(value):
                    builder.op(new PrintOp(expression(value, scope)));
            }
        }
        return builder.build();
    }

    function attribute(attribute:CheckedAttribute, scope:CompileScope,
            builder:SequenceBuilder):Void {
        var name = attribute.name;
        var prefix = ' ${name}="';
        switch [attribute.context, attribute.value] {
            case [_, Present]:
                builder.literal(' ${name}');
            case [Boolean, Bound(value)]:
                builder.op(new BooleanAttributeOp(Bytes.ofString(' ${name}'),
                    expression(value, scope)));
            case [Url, Bound(value)]:
                builder.op(new UrlAttributeOp(Bytes.ofString(prefix),
                    [new UrlPart(null, expression(value, scope))], true));
            case [Url, Static(parts)]:
                var urlParts = [
                    for (part in parts)
                        switch part {
                            case Literal(text):
                                new UrlPart(escapeAttribute(text), null);
                            case Print(value):
                                new UrlPart(null, expression(value, scope));
                        }
                ];
                if (isStatic(parts)) {
                    var text = literalText(parts);
                    var classification = Urls.classify(StringTools.htmlUnescape(text));
                    if (classification == Urls.SAFE) {
                        builder.literal('${prefix}${escapeAttribute(text)}"');
                        return;
                    }
                    if (classification == Urls.UNSAFE) {
                        builder.literal('${prefix}"');
                        return;
                    }
                }
                builder.op(new UrlAttributeOp(Bytes.ofString(prefix), urlParts, false));
            case [Srcset, Bound(value)]:
                builder.op(new SrcsetAttributeOp(Bytes.ofString(prefix), expression(value, scope)));
            case [Srcset, Static(parts)]:
                if (isStatic(parts)) {
                    builder.literal('${prefix}${escapeAttribute(literalText(parts))}"');
                } else {
                    builder.op(new SrcsetAttributeOp(Bytes.ofString(prefix), concat(parts, scope)));
                }
            case [_, Bound(value)]:
                builder.op(new BoundAttributeOp(Bytes.ofString(prefix), expression(value, scope)));
            case [_, Static(parts)]:
                builder.literal(prefix);
                for (part in parts) {
                    switch part {
                        case Literal(text):
                            builder.literal(escapeAttribute(text));
                        case Print(value):
                            builder.op(new PrintOp(expression(value, scope)));
                    }
                }
                builder.literal('"');
            case [_, Classes(parts, bound)]:
                var staticOp = parts.length == 0 ? null : attributeParts(parts, scope);
                var boundEval = bound == null ? null : expression(bound, scope);
                builder.op(new ClassAttributeOp(staticOp, boundEval, false));
        }
    }

    function component(component:CheckedComponent, scope:CompileScope,
            builder:SequenceBuilder):Void {
        var compiled = set.template(component.name);
        if (compiled.value == null) {
            error("component-compile", 'The component ${component.name} could not be compiled',
                component.position);
            return;
        }
        var callee = compiled.value;
        var propSlots:Array<Int> = [];
        var propValues:Array<Eval> = [];
        var given:Map<String, Bool> = [];
        for (prop in component.props) {
            var target = callee.prop(prop.prop.name);
            if (target == null) {
                continue;
            }
            given.set(prop.prop.name, true);
            propSlots.push(target.slot);
            propValues.push(propValue(prop, scope));
        }
        var defaultSlots:Array<Int> = [];
        var defaultValues:Array<Eval> = [];
        for (prop in callee.props) {
            if (!given.exists(prop.name) && prop.defaultValue != null) {
                defaultSlots.push(prop.slot);
                defaultValues.push(prop.defaultValue);
            }
        }
        var forwardedBuilder = new SequenceBuilder();
        var hasForwarded = false;
        var classParts:Null<Op> = null;
        var classBound:Null<Eval> = null;
        for (attribute in component.forwarded) {
            switch attribute.value {
                case Classes(parts, bound):
                    if (parts.length > 0) {
                        classParts = attributeParts(parts, scope);
                    }
                    if (bound != null) {
                        classBound = expression(bound, scope);
                    }
                default:
                    hasForwarded = true;
                    this.attribute(attribute, scope, forwardedBuilder);
            }
        }
        var forwardedClass = classParts == null
            && classBound == null ? null : new ClassAttributeOp(classParts, classBound, false);
        var slotNames:Array<String> = [];
        var slotBodies:Array<Op> = [];
        var slotLets:Array<Int> = [];
        for (content in component.slots) {
            var contentScope = scope;
            var letSlot = -1;
            if (content.variable != null) {
                letSlot = template.allocateSlot();
                contentScope = new CompileScope(scope, scope.loop);
                contentScope.bind(content.variable, letSlot);
            }
            slotNames.push(content.name);
            slotBodies.push(sequence(content.children, contentScope));
            slotLets.push(letSlot);
        }
        builder.op(new ComponentOp(callee, propSlots, propValues, defaultSlots, defaultValues,
            forwardedClass, hasForwarded ? forwardedBuilder.build() : null, slotNames, slotBodies,
            slotLets));
    }

    function propValue(prop:CheckedComponentProp, scope:CompileScope):Eval {
        return switch prop.value {
            case Bound(value):
                expression(value, scope);
            case Present:
                new ConstEval(true, KBool);
            case Static(parts):
                concat(parts, scope);
            case Classes(parts, _):
                concat(parts, scope);
        }
    }

    /** Static text as a string value; template text is markup, so entities are decoded. **/
    function concat(parts:Array<CheckedPart>, scope:CompileScope):Eval {
        if (isStatic(parts)) {
            return new ConstEval(StringTools.htmlUnescape(literalText(parts)), KString);
        }
        var literals:Array<Null<String>> = [];
        var values:Array<Null<Eval>> = [];
        for (part in parts) {
            switch part {
                case Literal(text):
                    literals.push(StringTools.htmlUnescape(text));
                    values.push(null);
                case Print(value):
                    literals.push(null);
                    values.push(expression(value, scope));
            }
        }
        return new ConcatEval(literals, values);
    }

    function callArguments(parameters:Array<Parameter>, arguments:Array<TypedArgument>,
            scope:CompileScope):CallArguments {
        var values:Array<Null<Eval>> = [for (_ in parameters) null];
        var extraNames:Array<String> = [];
        var extras:Array<Eval> = [];
        for (argument in arguments) {
            var value = expression(argument.value, scope);
            if (argument.parameter != null) {
                values[parameters.indexOf(argument.parameter)] = value;
            } else {
                extraNames.push(argument.name);
                extras.push(value);
            }
        }
        return new CallArguments(values, extraNames, extras);
    }

    function expression(value:TypedExpr, scope:CompileScope):Eval {
        var kind = Values.kindOf(value.type);
        switch value.kind {
            case Constant(constant):
                return switch constant {
                    case CString(text): new ConstEval(text, KString);
                    case CInt(number): new ConstEval(number, KInt);
                    case CFloat(number): new ConstEval(number, KFloat);
                    case CBool(flag): new ConstEval(flag, KBool);
                    case CNull: new ConstEval(null, KOther);
                }
            case Name(name, Loop):
                error("loop-value", "loop is read through its fields, such as loop.index",
                    value.position);
                return new ConstEval(null, KOther);
            case Name(name, _):
                var slot = scope.slot(name);
                if (slot < 0) {
                    error("internal", 'No frame slot for ${name}', value.position);
                    return new ConstEval(null, KOther);
                }
                return new SlotEval(slot, kind);
            case Root(name):
                return new RootEval(template.rootNames.indexOf(name), kind);
            case FieldAccess(target, view, field):
                var loop = loopOf(target, scope);
                if (loop != null) {
                    return loopField(loop, field.name, value.position);
                }
                return new FieldEval(expression(target, scope), field.name, kind);
            case IndexAccess(target, key):
                var isMap = Types.nonNull(target.type).match(TMap(_));
                return new IndexEval(expression(target, scope), expression(key, scope), isMap,
                    kind);
            case HelperCall(helper, arguments):
                var implementation = runtime.helper(helper.name);
                if (implementation == null) {
                    error("missing-implementation",
                        'The host has no implementation for the helper ${helper.name}',
                        value.position);
                    return new ConstEval(null, kind);
                }
                return new HelperEval(implementation,
                    callArguments(helper.parameters, arguments, scope), kind);
            case SourceCall(source, _):
                error("internal", 'A source call outside <sources>: ${source.name}',
                    value.position);
                return new ConstEval(null, kind);
            case FilterCall(target, filter, arguments):
                var implementation = runtime.filter(filter.name);
                if (implementation == null) {
                    error("missing-implementation",
                        'The host has no implementation for the filter ${filter.name}',
                        value.position);
                    return new ConstEval(null, kind);
                }
                var skipsNull = !Types.isNullable(filter.input) && filter.input != TAny;
                return new FilterEval(expression(target, scope), implementation,
                    callArguments(filter.parameters, arguments, scope), skipsNull, kind);
            case ListValue(items):
                return new ListEval([for (item in items) expression(item, scope)]);
            case RecordValue(entries):
                return new RecordEval([for (entry in entries) entry.name],
                    [for (entry in entries) expression(entry.value, scope)]);
            case UnaryOp(Not, operand):
                return new NotEval(expression(operand, scope));
            case UnaryOp(Negate, operand):
                return new NegateEval(expression(operand, scope), kind == KInt ? KInt : KFloat);
            case BinaryOp(operation, left, right):
                return binary(operation, left, right, kind, scope);
            case Choice(condition, consequent, alternative):
                return new ChoiceEval(expression(condition, scope), expression(consequent, scope),
                    alternative == null ? null : expression(alternative, scope), kind);
        }
    }

    function binary(operation:wellout.syntax.Expr.BinaryOperator, left:TypedExpr, right:TypedExpr,
            kind:ValueKind, scope:CompileScope):Eval {
        var a = expression(left, scope);
        var b = expression(right, scope);
        var numeric = Types.isNumber(Types.nonNull(left.type))
            && Types.isNumber(Types.nonNull(right.type));
        return switch operation {
            case And: new LogicEval(a, b, true);
            case Or: new LogicEval(a, b, false);
            case Coalesce: new CoalesceEval(a, b, kind);
            case Add: new ArithmeticEval(ArithmeticEval.ADD, a, b, kind == KInt ? KInt : KFloat);
            case Subtract: new ArithmeticEval(ArithmeticEval.SUBTRACT, a, b,
                    kind == KInt ? KInt : KFloat);
            case Multiply: new ArithmeticEval(ArithmeticEval.MULTIPLY, a, b,
                    kind == KInt ? KInt : KFloat);
            case Divide: new ArithmeticEval(ArithmeticEval.DIVIDE, a, b, KFloat);
            case Modulo: new ArithmeticEval(ArithmeticEval.MODULO, a, b,
                    kind == KInt ? KInt : KFloat);
            case Equal: new CompareEval(CompareEval.EQUAL, a, b, numeric);
            case NotEqual: new CompareEval(CompareEval.NOT_EQUAL, a, b, numeric);
            case Less: new CompareEval(CompareEval.LESS, a, b, numeric);
            case LessOrEqual: new CompareEval(CompareEval.LESS_OR_EQUAL, a, b, numeric);
            case Greater: new CompareEval(CompareEval.GREATER, a, b, numeric);
            case GreaterOrEqual: new CompareEval(CompareEval.GREATER_OR_EQUAL, a, b, numeric);
            case In: new InEval(a, b);
        }
    }

    /** The loop id a `loop` or `loop.parent…` expression names, or null. **/
    function loopOf(value:TypedExpr, scope:CompileScope):Null<Int> {
        return switch value.kind {
            case Name(_, Loop):
                scope.loop;
            case FieldAccess(target, _, field) if (field.name == "parent"):
                var inner = loopOf(target, scope);
                inner == null ? null : inner < 0 ? -1 : template.loopParents[inner];
            default:
                null;
        }
    }

    function loopField(loop:Int, field:String, position:Position):Eval {
        return switch field {
            case "index": new LoopFieldEval(loop, LoopFieldEval.INDEX);
            case "number": new LoopFieldEval(loop, LoopFieldEval.NUMBER);
            case "first": new LoopFieldEval(loop, LoopFieldEval.FIRST);
            case "last": new LoopFieldEval(loop, LoopFieldEval.LAST);
            case "length": new LoopFieldEval(loop, LoopFieldEval.LENGTH);
            default:
                error("loop-value", 'loop.${field} cannot be used as a value', position);
                new ConstEval(null, KOther);
        }
    }

    function error(code:String, message:String, position:Position):Void {
        diagnostics.push(new Diagnostic(code, message, position));
    }
}
