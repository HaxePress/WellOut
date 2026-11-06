package wellout.check;

import wellout.Result;
import wellout.check.CheckedTemplate;
import wellout.check.ComponentSignature;
import wellout.check.Scope;
import wellout.check.TypedExpr;
import wellout.check.Types;
import wellout.syntax.Ast;
import wellout.syntax.Diagnostic;
import wellout.syntax.Expr;
import wellout.syntax.ExpressionParser;
import wellout.syntax.Position;

using StringTools;

/**
    Checks a parsed template against a host contract and a component
    resolver (SPEC §3–§9): declarations, scopes, directive chains,
    attribute contexts, component calls, slots, head content, islands and
    assets. The result is a `CheckedTemplate` with every expression typed.
    Checking continues after errors, so one run reports as much as it can.
**/
class TemplateChecker {
    static final identifier = ~/^[A-Za-z_][A-Za-z0-9_]*$/;
    static final fragmentName = ~/^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
    static final slotName = ~/^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
    static final assetPath = ~/^[A-Za-z0-9_][A-Za-z0-9_\/.-]*$/;
    static final urlAttributes:Map<String, Bool> = [
        "href" => true,
        "src" => true,
        "action" => true,
        "formaction" => true,
        "poster" => true,
        "cite" => true,
        "data" => true,
        "xlink:href" => true
    ];
    static final booleanAttributes:Map<String, Bool> = [
        for (name in [
            "allowfullscreen",
            "async",
            "autofocus",
            "autoplay",
            "checked",
            "controls",
            "default",
            "defer",
            "disabled",
            "formnovalidate",
            "hidden",
            "inert",
            "ismap",
            "itemscope",
            "loop",
            "multiple",
            "muted",
            "nomodule",
            "novalidate",
            "open",
            "playsinline",
            "readonly",
            "required",
            "reversed",
            "selected"
        ])
            name => true
    ];
    static final rejectedElements:Map<String, Bool> = [
        for (name in [
            "script",
            "style",
            "iframe",
            "object",
            "embed",
            "base",
            "frame",
            "frameset",
            "applet",
            "foreignObject",
            "noscript",
            "portal"
        ])
            name => true
    ];
    static final headElements:Map<String, Bool> = ["title" => true, "meta" => true, "link" => true];
    static final builtins = ["well:head", "HeadOutlet", "Island", "Asset", "Assets"];
    static final islandLoads = ["eager", "idle", "visible", "interaction"];

    final contract:HostContract;
    final components:ComponentResolver;
    final name:String;
    final trusted:Bool;
    final diagnostics:Array<Diagnostic> = [];
    final used:Map<String, Bool> = [];
    final fragments:Map<String, Bool> = [];
    final slots:Array<SlotSignature> = [];
    var acceptsAttributes = false;
    var headOutlet = false;
    var headDepth = 0;

    /** Loop variables bound inside the current `<well:head>`, which it may read. **/
    final headLocals:Map<String, Bool> = [];

    public static function check(document:Document, contract:HostContract,
            components:ComponentResolver, name:String = "template",
            trusted:Bool = true):Result<CheckedTemplate> {
        var checker = new TemplateChecker(contract, components, name, trusted);
        var template = checker.run(document);
        return new Result(template, checker.diagnostics);
    }

    function new(contract:HostContract, components:ComponentResolver, name:String, trusted:Bool) {
        this.contract = contract;
        this.components = components;
        this.name = name;
        this.trusted = trusted;
    }

    function run(document:Document):CheckedTemplate {
        var scope = new Scope();
        var props:Array<CheckedProp> = [];
        var signatures:Array<PropSignature> = [];
        for (declaration in document.props) {
            var prop = checkProp(declaration);
            if (prop != null) {
                props.push(prop);
                scope.bind(prop.name, Prop, prop.type);
                var required = prop.defaultValue == null && !Types.isNullable(prop.type);
                signatures.push(new PropSignature(prop.name, prop.type, required));
            }
        }
        var sources:Array<CheckedSource> = [];
        for (declaration in document.sources) {
            var source = checkSource(declaration, scope);
            if (source != null) {
                sources.push(source);
            }
        }
        for (source in sources) {
            scope.bind(source.name, Source, source.type);
        }
        var nodes = checkNodes(document.children, scope);
        for (prop in props) {
            if (!used.exists(prop.name)) {
                warn("unused-prop", 'The prop ${prop.name} is not used', prop.position);
            }
        }
        for (source in sources) {
            if (!used.exists(source.name)) {
                warn("unused-source", 'The source ${source.name} is not used', source.position);
            }
        }
        var signature = new ComponentSignature(name, signatures, slots, acceptsAttributes);
        return new CheckedTemplate(name, props, sources, signature, nodes);
    }

    function checkProp(declaration:Declaration):Null<CheckedProp> {
        if (!identifier.match(declaration.name) || declaration.name == "loop") {
            error("invalid-name", 'The prop name ${declaration.name} is not a valid name',
                declaration.position, "Use letters, digits and _, starting with a letter");
            return null;
        }
        if (contract.root(declaration.name) != null) {
            error("shadowed-root", 'The prop ${declaration.name} hides an implicit root',
                declaration.position);
            return null;
        }
        var parsed = ExpressionParser.parseProp(declaration.value, declaration.valuePosition);
        report(parsed.diagnostics);
        if (parsed.value == null) {
            return null;
        }
        var type = Types.resolve(parsed.value.type, contract, diagnostics);
        if (type == null) {
            return null;
        }
        var defaultValue:Null<TypedExpr> = null;
        if (parsed.value.defaultValue != null) {
            var checked = ExpressionChecker.check(parsed.value.defaultValue, new Scope(), contract);
            report(checked.diagnostics);
            if (checked.value == null) {
                return null;
            }
            if (!Types.assignable(checked.value.type, type, [])) {
                error("default-type",
                    'The default of ${declaration.name} is ${Types.print(checked.value.type)}, not ${Types.print(type)}',
                    checked.value.position);
                return null;
            }
            defaultValue = checked.value;
        }
        return new CheckedProp(declaration.name, type, defaultValue, declaration.position);
    }

    function checkSource(declaration:Declaration, scope:Scope):Null<CheckedSource> {
        if (!identifier.match(declaration.name) || declaration.name == "loop") {
            error("invalid-name", 'The source name ${declaration.name} is not a valid name',
                declaration.position);
            return null;
        }
        if (scope.lookup(declaration.name) != null || contract.root(declaration.name) != null) {
            error("duplicate-name", 'The name ${declaration.name} is already declared',
                declaration.position);
            return null;
        }
        var parsed = ExpressionParser.parse(declaration.value, declaration.valuePosition);
        report(parsed.diagnostics);
        if (parsed.value == null) {
            return null;
        }
        var checked = ExpressionChecker.checkSourceCall(parsed.value, scope, contract);
        report(checked.diagnostics);
        if (checked.value == null) {
            return null;
        }
        markUsed(checked.value);
        return new CheckedSource(declaration.name, checked.value.type, checked.value,
            declaration.position);
    }

    /** Checks siblings, folding `:if` chains and `:for` with `:empty` into single nodes. **/
    function checkNodes(nodes:Array<Node>, scope:Scope):Array<CheckedNode> {
        var checked:Array<CheckedNode> = [];
        var index = 0;
        while (index < nodes.length) {
            switch nodes[index] {
                case Text(text):
                    checked.push(checkText(text, scope));
                    index++;
                case Doctype(text, _):
                    checked.push(Doctype(text));
                    index++;
                case Element(element):
                    if (element.directive(For) != null) {
                        index = checkRepeat(nodes, index, scope, checked);
                    } else if (element.directive(If) != null) {
                        index = checkBranches(nodes, index, scope, checked);
                    } else if (element.directive(ElseIf) != null
                        || element.directive(Else) != null || element.directive(Empty) != null) {
                        // The parser already reported the misplaced branch.
                        index++;
                    } else {
                        var node = checkElement(element, scope);
                        if (node != null) {
                            checked.push(node);
                        }
                        index++;
                    }
            }
        }
        return checked;
    }

    /** The index of the next element sibling after whitespace-only text, or -1. **/
    static function nextElement(nodes:Array<Node>, from:Int):Int {
        var index = from;
        while (index < nodes.length) {
            switch nodes[index] {
                case Text(text) if (text.isWhitespace()):
                    index++;
                case Element(_):
                    return index;
                default:
                    return -1;
            }
        }
        return -1;
    }

    static function elementAt(nodes:Array<Node>, index:Int):Null<ElementNode> {
        if (index < 0) {
            return null;
        }
        return switch nodes[index] {
            case Element(element): element;
            default: null;
        }
    }

    function checkBranches(nodes:Array<Node>, start:Int, scope:Scope,
            checked:Array<CheckedNode>):Int {
        var branches:Array<CheckedBranch> = [];
        var element = elementAt(nodes, start);
        var next = start + 1;
        var directive = element.directive(If);
        while (true) {
            var condition:Null<TypedExpr> = null;
            var branchScope = scope;
            switch directive.kind {
                case Directive(_, source, position) if (source != null):
                    var parsed = ExpressionParser.parse(source, position);
                    report(parsed.diagnostics);
                    if (parsed.value != null) {
                        condition = expression(parsed.value, scope);
                        branchScope = scope.child();
                        ConditionFacts.of(parsed.value).applyTo(branchScope);
                    }
                default:
            }
            var node = element.directive(For) != null ? repeatNode(element,
                branchScope) : checkElement(element, branchScope);
            if (node != null) {
                branches.push(new CheckedBranch(condition, node));
            }
            if (directive.kind.match(Directive(Else, _, _))) {
                break;
            }
            var following = nextElement(nodes, next);
            var sibling = elementAt(nodes, following);
            if (sibling == null) {
                break;
            }
            var elseIf = sibling.directive(ElseIf);
            var otherwise = sibling.directive(Else);
            if (elseIf == null && otherwise == null) {
                break;
            }
            element = sibling;
            directive = elseIf != null ? elseIf : otherwise;
            next = following + 1;
        }
        checked.push(Branches(branches));
        return next;
    }

    function checkRepeat(nodes:Array<Node>, start:Int, scope:Scope,
            checked:Array<CheckedNode>):Int {
        var element = elementAt(nodes, start);
        var next = start + 1;
        var directive = element.directive(For);
        var repeat:Null<CheckedRepeat> = null;
        switch directive.kind {
            case Directive(_, source, position) if (source != null):
                var parsed = ExpressionParser.parseLoop(source, position);
                report(parsed.diagnostics);
                if (parsed.value != null) {
                    repeat = checkLoop(element, parsed.value, scope);
                }
            default:
        }
        var following = nextElement(nodes, next);
        var sibling = elementAt(nodes, following);
        var empty:Null<CheckedNode> = null;
        if (sibling != null && sibling.directive(Empty) != null) {
            empty = checkElement(sibling, scope);
            next = following + 1;
        }
        if (repeat != null) {
            checked.push(Repeat(new CheckedRepeat(repeat.variable, repeat.list, repeat.body,
                empty, repeat.position)));
        }
        return next;
    }

    /** A branch element that also repeats, such as `<li :else :for="…">`. **/
    function repeatNode(element:ElementNode, scope:Scope):Null<CheckedNode> {
        var directive = element.directive(For);
        switch directive.kind {
            case Directive(_, source, position) if (source != null):
                var parsed = ExpressionParser.parseLoop(source, position);
                report(parsed.diagnostics);
                if (parsed.value == null) {
                    return null;
                }
                var repeat = checkLoop(element, parsed.value, scope);
                return repeat == null ? null : Repeat(repeat);
            default:
                return null;
        }
    }

    function checkLoop(element:ElementNode, loop:LoopSyntax, scope:Scope):Null<CheckedRepeat> {
        if (loop.variable == "loop") {
            error("invalid-name", "loop is reserved for loop metadata", loop.variablePosition);
            return null;
        }
        var list = expression(loop.list, scope);
        if (list == null) {
            return null;
        }
        var item = switch Types.nonNull(list.type) {
            case TList(item): item;
            default: null;
        }
        if (item == null) {
            error("for-list-type", ':for needs a list but got ${Types.print(list.type)}',
                list.position);
            return null;
        }
        var body = scope.child();
        body.bind(loop.variable, Variable, item);
        body.bind("loop", Loop, TView("Loop"));
        if (headDepth > 0) {
            headLocals.set(loop.variable, true);
            headLocals.set("loop", true);
        }
        var node = checkElement(element, body);
        if (node == null) {
            return null;
        }
        return new CheckedRepeat(loop.variable, list, node, null, element.position);
    }

    function checkText(text:TextNode, scope:Scope):CheckedNode {
        return Text(checkParts(text.parts, scope, null));
    }

    /** Checks text parts; `context` is the attribute context, or null for element text. **/
    function checkParts(parts:Array<TextPart>, scope:Scope,
            context:Null<AttributeContext>):Array<CheckedPart> {
        var checked:Array<CheckedPart> = [];
        for (part in parts) {
            switch part {
                case Literal(text):
                    checked.push(Literal(text));
                case Interpolation(source, position):
                    var parsed = ExpressionParser.parse(source, position);
                    report(parsed.diagnostics);
                    if (parsed.value == null) {
                        continue;
                    }
                    var value = expression(parsed.value, scope);
                    if (value == null) {
                        continue;
                    }
                    if (context == null) {
                        requirePrintable(value, true);
                    } else if (context == Style) {
                        requireCss(value);
                    } else {
                        requirePrintable(value, false);
                    }
                    checked.push(Print(value));
            }
        }
        return checked;
    }

    function checkElement(element:ElementNode, scope:Scope,
            ignoreSlotAttribute:Bool = false):Null<CheckedNode> {
        return switch element.kind {
            case HtmlElement | VoidElement | RawTextElement:
                checkHtmlElement(element, scope, ignoreSlotAttribute);
            case TemplateElement:
                checkTemplateElement(element, scope, ignoreSlotAttribute);
            case SlotElement:
                checkSlotOutlet(element, scope);
            case ComponentElement:
                checkComponentElement(element, scope, ignoreSlotAttribute);
            case PropsDeclaration | SourcesDeclaration:
                null;
        }
    }

    function checkHtmlElement(element:ElementNode, scope:Scope,
            ignoreSlotAttribute:Bool):Null<CheckedNode> {
        if (!trusted && rejectedElements.exists(element.name)) {
            error("rejected-element",
                'Templates installed at runtime cannot use <${element.name}>', element.position);
            return null;
        }
        if (headDepth > 0 && !headElements.exists(element.name)) {
            error("head-content", '<well:head> may contain only <title>, <meta> and <link>',
                element.position);
            return null;
        }
        var attributes:Array<CheckedAttribute> = [];
        var fragment:Null<String> = null;
        var swap:Null<AttributeValue> = null;
        var forwards = false;
        var staticClass:Null<Array<CheckedPart>> = null;
        var boundClass:Null<TypedExpr> = null;
        var classSeen = false;
        for (attribute in element.attributes) {
            switch attribute.kind {
                case Directive(Attrs, _, _):
                    if (acceptsAttributes) {
                        error("duplicate-attrs", "Only one element may carry :attrs",
                            attribute.position);
                    }
                    acceptsAttributes = true;
                    forwards = true;
                    continue;
                case Directive(Let, _, _):
                    error("misplaced-let", ":let belongs on slot content of a component call",
                        attribute.position);
                    continue;
                case Directive(_, _, _):
                    continue;
                default:
            }
            switch attribute.name {
                case "slot":
                    if (!ignoreSlotAttribute) {
                        error("misplaced-slot-attribute",
                            "slot is allowed only on direct children of a component call",
                            attribute.position);
                    }
                    continue;
                case "fragment":
                    fragment = fragmentOf(attribute);
                    continue;
                case "swap":
                    swap = attributeValue(attribute, scope, Plain);
                    continue;
                case "class":
                    classSeen = true;
                    switch attribute.kind {
                        case StaticValue(parts):
                            staticClass = checkParts(parts, scope, Plain);
                        case Binding(source, position):
                            boundClass = classExpression(source, position, scope);
                        default:
                            staticClass = [];
                    }
                    continue;
                case "srcdoc":
                    error("rejected-attribute", "srcdoc is not allowed", attribute.position);
                    continue;
                default:
            }
            var context = contextOf(attribute.name);
            var value = attributeValue(attribute, scope, context);
            if (value != null) {
                attributes.push(new CheckedAttribute(attribute.name, value, context));
            }
        }
        if (classSeen) {
            var parts = staticClass == null ? [] : staticClass;
            attributes.unshift(new CheckedAttribute("class", Classes(parts, boundClass),
                ClassList));
        }
        var children:Array<CheckedNode> = if (element.kind == RawTextElement) {
            [for (node in element.children) rawText(node)];
        } else {
            checkNodes(element.children, scope);
        };
        var isVoid = element.kind == VoidElement;
        var isRaw = element.kind == RawTextElement;
        return Element(new CheckedElement(element.name, attributes, children, isVoid, isRaw,
            fragment, swap, forwards, element.position));
    }

    static function rawText(node:Node):CheckedNode {
        return switch node {
            case Text(text):
                Text([
                    for (part in text.parts)
                        switch part {
                            case Literal(value):
                                Literal(value);
                            case Interpolation(source, _):
                                Literal('{{${source}}}');
                        }
                ]);
            default:
                Text([]);
        }
    }

    function fragmentOf(attribute:Attribute):Null<String> {
        var text = staticText(attribute);
        if (text == null || !fragmentName.match(text)) {
            error("invalid-fragment", "A fragment name is static text such as \"results\"",
                attribute.position);
            return null;
        }
        if (fragments.exists(text)) {
            error("duplicate-fragment", 'The fragment ${text} is already declared',
                attribute.position);
            return null;
        }
        fragments.set(text, true);
        return text;
    }

    /** The value of an attribute written as plain text without interpolation, or null. **/
    static function staticText(attribute:Attribute):Null<String> {
        return switch attribute.kind {
            case StaticValue([]):
                "";
            case StaticValue([Literal(text)]):
                text;
            default:
                null;
        }
    }

    function classExpression(source:String, position:Position, scope:Scope):Null<TypedExpr> {
        var parsed = ExpressionParser.parse(source, position);
        report(parsed.diagnostics);
        if (parsed.value == null) {
            return null;
        }
        var value = expression(parsed.value, scope);
        if (value == null) {
            return null;
        }
        if (!isClassValue(value.type)) {
            error("class-type",
                ':class takes a string or a list of strings, not ${Types.print(value.type)}',
                value.position);
            return null;
        }
        return value;
    }

    static function isClassValue(type:WellType):Bool {
        return switch Types.nonNull(type) {
            case TString | TAny:
                true;
            case TList(item):
                switch Types.nonNull(item) {
                    case TString | TAny: true;
                    default: false;
                }
            default:
                false;
        }
    }

    static function contextOf(name:String):AttributeContext {
        var lowered = name.toLowerCase();
        if (urlAttributes.exists(lowered)) {
            return Url;
        }
        if (lowered == "srcset") {
            return Srcset;
        }
        if (lowered == "style") {
            return Style;
        }
        if (booleanAttributes.exists(lowered)) {
            return Boolean;
        }
        return Plain;
    }

    function attributeValue(attribute:Attribute, scope:Scope,
            context:AttributeContext):Null<AttributeValue> {
        return switch attribute.kind {
            case Present:
                Present;
            case StaticValue(parts):
                Static(checkParts(parts, scope, context));
            case Binding(source, position):
                var parsed = ExpressionParser.parse(source, position);
                report(parsed.diagnostics);
                if (parsed.value == null) {
                    return null;
                }
                var value = expression(parsed.value, scope);
                if (value == null) {
                    return null;
                }
                switch context {
                    case Boolean:
                    case Style:
                        requireCss(value);
                    case Url | Srcset:
                        requireUrl(value);
                    default:
                        requirePrintable(value, false);
                }
                Bound(value);
            case Directive(_, _, _):
                null;
        }
    }

    function checkTemplateElement(element:ElementNode, scope:Scope,
            ignoreSlotAttribute:Bool):Null<CheckedNode> {
        for (attribute in element.attributes) {
            switch attribute.kind {
                case Directive(If | ElseIf | Else | For | Empty, _, _):
                case Directive(Let, _, _) if (ignoreSlotAttribute):
                case _ if (attribute.name == "slot" && ignoreSlotAttribute):
                case _ if (attribute.name == "slot"):
                    error("misplaced-slot-attribute",
                        "slot is allowed only on direct children of a component call",
                        attribute.position);
                default:
                    error("template-attribute",
                        '<template> takes only control directives, not ${attribute.name}',
                        attribute.position);
            }
        }
        return Group(checkNodes(element.children, scope));
    }

    function checkSlotOutlet(element:ElementNode, scope:Scope):Null<CheckedNode> {
        var slot = ComponentSignature.DEFAULT_SLOT;
        var exposes:Null<TypedExpr> = null;
        for (attribute in element.attributes) {
            switch attribute.kind {
                case Directive(_, _, _):
                    continue;
                case Binding(source, position):
                    if (exposes != null) {
                        error("slot-value", "A slot exposes at most one value", attribute.position);
                        continue;
                    }
                    var parsed = ExpressionParser.parse(source, position);
                    report(parsed.diagnostics);
                    if (parsed.value != null) {
                        exposes = expression(parsed.value, scope);
                    }
                case _ if (attribute.name == "name"):
                    var text = staticText(attribute);
                    if (text == null || !slotName.match(text)) {
                        error("invalid-slot-name",
                            "A slot name is static text such as \"footer\"", attribute.position);
                    } else {
                        slot = text;
                    }
                default:
                    error("slot-attribute",
                        '<slot> takes name and one bound value, not ${attribute.name}',
                        attribute.position);
            }
        }
        var exposedType = exposes == null ? null : exposes.type;
        var existing:Null<SlotSignature> = null;
        for (known in slots) {
            if (known.name == slot) {
                existing = known;
            }
        }
        if (existing == null) {
            slots.push(new SlotSignature(slot, exposedType));
        } else if ((existing.exposes == null) != (exposedType == null)
            || (exposedType != null && Types.unify(existing.exposes, exposedType) == null)) {
            error("slot-value", 'The slot ${slot} exposes different values', element.position);
        }
        var fallback = checkNodes(element.children, scope);
        return SlotOutlet(new CheckedSlotOutlet(slot, exposes, fallback));
    }

    function checkComponentElement(element:ElementNode, scope:Scope,
            ignoreSlotAttribute:Bool):Null<CheckedNode> {
        switch element.name {
            case "well:head":
                return checkHead(element, scope);
            case "Head":
                error("renamed-head", "<well:head> is written <well:head>", element.position,
                    "HTML formatters lower-case <well:head> to <head>, so the head component has a prefix");
                return null;
            case "HeadOutlet":
                return checkHeadOutlet(element);
            case "Island":
                return checkIsland(element, scope);
            case "Asset":
                return checkAsset(element);
            case "Assets":
                requireNoAttributes(element);
                return Assets;
            default:
        }
        if (headDepth > 0) {
            error("head-content", '<well:head> may contain only <title>, <meta> and <link>',
                element.position);
            return null;
        }
        var signature = components.resolve(element.name);
        if (signature == null) {
            if (components.has(element.name)) {
                error("component-errors", 'The component ${element.name} has errors',
                    element.position, 'Fix the diagnostics in ${element.name} first');
            } else {
                var candidates = builtins.concat(components.names());
                error("unknown-component", 'Unknown component <${element.name}>',
                    element.position, Suggestions.hint(element.name, candidates));
            }
            return null;
        }
        if (signature.incomplete) {
            error("recursive-component", 'The component ${element.name} renders itself',
                element.position);
            return null;
        }
        var props:Array<CheckedComponentProp> = [];
        var forwarded:Array<CheckedAttribute> = [];
        var given:Map<String, Bool> = [];
        var defaultVariable:Null<String> = null;
        for (attribute in element.attributes) {
            switch attribute.kind {
                case Directive(Let, source, _):
                    defaultVariable = letName(source, attribute.position);
                    continue;
                case Directive(If | ElseIf | Else | For | Empty, _, _):
                    continue;
                case Directive(_, _, _):
                    error("component-directive",
                        'Components do not take ${attribute.name}; put it on an element inside',
                        attribute.position);
                    continue;
                default:
            }
            if (attribute.name == "slot" && ignoreSlotAttribute) {
                continue;
            }
            if (attribute.name == "fragment" || attribute.name == "swap"
                || attribute.name == "slot") {
                error("component-reserved-attribute",
                    '${attribute.name} belongs on an element, not on a component call',
                    attribute.position, "Wrap the component in an element");
                continue;
            }
            var prop = signature.prop(attribute.name);
            if (prop == null) {
                if (signature.acceptsAttributes && forwardable(attribute.name)) {
                    var context = attribute.name == "class" ? ClassList : Plain;
                    var value = attribute.name == "class" ? classValue(attribute,
                        scope) : attributeValue(attribute, scope, context);
                    if (value != null) {
                        forwarded.push(new CheckedAttribute(attribute.name, value, context));
                    }
                } else {
                    error("unknown-prop", '<${element.name}> has no prop ${attribute.name}',
                        attribute.position,
                        Suggestions.hint(attribute.name, signature.propNames()));
                }
                continue;
            }
            given.set(prop.name, true);
            var value = propValue(element.name, prop, attribute, scope);
            if (value != null) {
                props.push(new CheckedComponentProp(prop, value));
            }
        }
        for (prop in signature.props) {
            if (prop.required && !given.exists(prop.name)) {
                error("missing-prop", '<${element.name}> needs the prop ${prop.name}',
                    element.position);
            }
        }
        var contents = checkSlotContents(element, signature, scope, defaultVariable);
        return Component(new CheckedComponent(element.name, signature, props, forwarded, contents,
            element.position));
    }

    static function forwardable(name:String):Bool {
        return name == "class" || name == "id" || name == "title" || name == "role"
            || name.startsWith("aria-") || name.startsWith("data-");
    }

    function classValue(attribute:Attribute, scope:Scope):Null<AttributeValue> {
        return switch attribute.kind {
            case StaticValue(parts):
                Classes(checkParts(parts, scope, Plain), null);
            case Binding(source, position):
                var bound = classExpression(source, position, scope);
                bound == null ? null : Classes([], bound);
            default:
                null;
        }
    }

    function propValue(component:String, prop:PropSignature, attribute:Attribute,
            scope:Scope):Null<AttributeValue> {
        switch attribute.kind {
            case Present:
                if (Types.nonNull(prop.type) != TBool) {
                    error("prop-type", 'The prop ${prop.name} of <${component}> needs a value',
                        attribute.position);
                    return null;
                }
                return Present;
            case StaticValue(parts):
                var base = Types.nonNull(prop.type);
                if (base != TString && base != TUrl && base != TAny) {
                    error("prop-type",
                        'The prop ${prop.name} of <${component}> is ${Types.print(prop.type)}; static text is String',
                        attribute.position, 'Bind it with :${prop.name}="…"');
                    return null;
                }
                return Static(checkParts(parts, scope, base == TUrl ? Url : Plain));
            case Binding(source, position):
                var parsed = ExpressionParser.parse(source, position);
                report(parsed.diagnostics);
                if (parsed.value == null) {
                    return null;
                }
                var value = expression(parsed.value, scope);
                if (value == null) {
                    return null;
                }
                if (!Types.assignable(value.type, prop.type, [])) {
                    var hint = Types.isNullable(value.type)
                        && !Types.isNullable(prop.type) ? "Supply a value with ?? or test it with :if" : null;
                    error("prop-type",
                        'The prop ${prop.name} of <${component}> expects ${Types.print(prop.type)} but got ${Types.print(value.type)}',
                        value.position, hint);
                    return null;
                }
                return Bound(value);
            case Directive(_, _, _):
                return null;
        }
    }

    function letName(source:Null<String>, position:Position):Null<String> {
        if (source == null || !identifier.match(source) || source == "loop") {
            error("invalid-let", ":let takes a variable name", position);
            return null;
        }
        return source;
    }

    function checkSlotContents(element:ElementNode, signature:ComponentSignature, scope:Scope,
            defaultVariable:Null<String>):Array<CheckedSlotContent> {
        var contents:Array<CheckedSlotContent> = [];
        var named:Map<String, Bool> = [];
        var defaultNodes:Array<Node> = [];
        for (node in element.children) {
            var child = switch node {
                case Element(child): child;
                default: null;
            }
            var slotAttribute = child == null ? null : attributeNamed(child, "slot");
            if (slotAttribute == null) {
                defaultNodes.push(node);
                continue;
            }
            var slot = staticText(slotAttribute);
            if (slot == null || !slotName.match(slot)) {
                error("invalid-slot-name", "A slot name is static text such as \"footer\"",
                    slotAttribute.position);
                continue;
            }
            if (named.exists(slot)) {
                error("duplicate-slot-content", 'The slot ${slot} is filled twice',
                    slotAttribute.position);
                continue;
            }
            named.set(slot, true);
            var signatureSlot = signature.slot(slot);
            if (signatureSlot == null) {
                error("unknown-slot", '<${element.name}> has no slot ${slot}',
                    slotAttribute.position, Suggestions.hint(slot, signature.slotNames()));
                continue;
            }
            var variable:Null<String> = null;
            var letDirective = child.directive(Let);
            if (letDirective != null) {
                switch letDirective.kind {
                    case Directive(_, source, _):
                        variable = letName(source, letDirective.position);
                    default:
                }
            }
            var contentScope = slotScope(scope, signatureSlot, variable, child.position);
            var nodes = if (child.kind == TemplateElement) {
                checkTemplateElement(child, contentScope, true);
            } else {
                checkElement(child, contentScope, true);
            }
            var children = switch nodes {
                case null: [];
                case Group(children): children;
                case other: [other];
            }
            contents.push(new CheckedSlotContent(slot, variable, children));
        }
        var hasDefault = false;
        for (node in defaultNodes) {
            switch node {
                case Text(text) if (text.isWhitespace()):
                default:
                    hasDefault = true;
            }
        }
        if (hasDefault || defaultVariable != null) {
            var signatureSlot = signature.slot(ComponentSignature.DEFAULT_SLOT);
            if (signatureSlot == null) {
                error("unknown-slot", '<${element.name}> has no default slot', element.position,
                    signature.slots.length > 0 ? 'Fill a named slot with <template slot="${signature.slots[0].name}">' : null);
            } else {
                var contentScope = slotScope(scope, signatureSlot, defaultVariable,
                    element.position);
                contents.push(new CheckedSlotContent(ComponentSignature.DEFAULT_SLOT,
                    defaultVariable, checkNodes(defaultNodes, contentScope)));
            }
        }
        return contents;
    }

    function slotScope(scope:Scope, slot:SlotSignature, variable:Null<String>,
            position:Position):Scope {
        if (variable == null) {
            return scope;
        }
        if (slot.exposes == null) {
            error("slot-without-value", 'The slot ${slot.name} exposes no value for :let',
                position);
            return scope;
        }
        var child = scope.child();
        child.bind(variable, Variable, slot.exposes);
        return child;
    }

    static function attributeNamed(element:ElementNode, name:String):Null<Attribute> {
        for (attribute in element.attributes) {
            if (attribute.name == name && !attribute.kind.match(Directive(_, _, _))) {
                return attribute;
            }
        }
        return null;
    }

    function checkHead(element:ElementNode, scope:Scope):Null<CheckedNode> {
        if (headDepth > 0) {
            error("nested-head", "<well:head> cannot contain another <well:head>",
                element.position);
            return null;
        }
        requireNoAttributes(element);
        headDepth++;
        var children = checkNodes(element.children, scope);
        headDepth--;
        headLocals.clear();
        return Head(children);
    }

    function checkHeadOutlet(element:ElementNode):Null<CheckedNode> {
        requireNoAttributes(element);
        if (element.children.length > 0) {
            error("head-outlet", "<HeadOutlet /> takes no content", element.position);
        }
        if (headOutlet) {
            error("duplicate-head-outlet", "A template has at most one <HeadOutlet />",
                element.position);
            return null;
        }
        headOutlet = true;
        return HeadOutlet;
    }

    function checkIsland(element:ElementNode, scope:Scope):Null<CheckedNode> {
        var islandName:Null<String> = null;
        var props:Null<TypedExpr> = null;
        var load = "eager";
        var propsGiven = false;
        for (attribute in element.attributes) {
            switch [attribute.name, attribute.kind] {
                case ["name", StaticValue(_)]:
                    islandName = staticText(attribute);
                case ["load", StaticValue(_)]:
                    var text = staticText(attribute);
                    if (text == null || islandLoads.indexOf(text) < 0) {
                        error("island-load", "load is eager, idle, visible or interaction",
                            attribute.position);
                    } else {
                        load = text;
                    }
                case ["props", Binding(source, position)]:
                    propsGiven = true;
                    var parsed = ExpressionParser.parse(source, position);
                    report(parsed.diagnostics);
                    if (parsed.value != null) {
                        props = expression(parsed.value, scope);
                    }
                case [_, Directive(_, _, _)]:
                default:
                    error("island-attribute",
                        '<Island> takes name, :props and load, not ${attribute.name}',
                        attribute.position);
            }
        }
        if (islandName == null) {
            error("island-name", "<Island> needs a static name", element.position);
            return null;
        }
        var signature = contract.island(islandName);
        if (signature == null) {
            error("unknown-island", 'Unknown island ${islandName}', element.position,
                Suggestions.hint(islandName, contract.islandNames()));
            return null;
        }
        var expectsProps = switch signature.props {
            case TRecord([]): false;
            default: true;
        }
        if (expectsProps && !propsGiven) {
            error("island-props", 'The island ${islandName} needs :props', element.position);
            return null;
        }
        if (props != null && !Types.assignable(props.type, signature.props, [])) {
            error("island-props",
                'The island ${islandName} expects ${Types.print(signature.props)} but got ${Types.print(props.type)}',
                props.position);
            return null;
        }
        var fallback = checkNodes(element.children, scope);
        return Island(new CheckedIsland(signature, props, load, fallback));
    }

    function checkAsset(element:ElementNode):Null<CheckedNode> {
        var found:Null<CheckedNode> = null;
        for (attribute in element.attributes) {
            var path = staticText(attribute);
            var kind = attribute.name == "css" ? Css : attribute.name == "js" ? Js : null;
            if (kind == null || path == null || found != null) {
                error("invalid-asset", '<Asset> takes one css or js path', attribute.position);
                continue;
            }
            if (!assetPath.match(path) || path.indexOf("..") >= 0) {
                error("invalid-asset", 'The asset path ${path} is not a plain relative path',
                    attribute.position);
                continue;
            }
            found = Asset(kind, path);
        }
        if (found == null && element.attributes.length == 0) {
            error("invalid-asset", '<Asset> takes one css or js path', element.position);
        }
        return found;
    }

    function requireNoAttributes(element:ElementNode):Void {
        for (attribute in element.attributes) {
            if (!attribute.kind.match(Directive(If | ElseIf | Else | For | Empty, _, _))) {
                error("unexpected-attribute", '<${element.name}> takes no attributes',
                    attribute.position);
            }
        }
    }

    function requirePrintable(value:TypedExpr, inText:Bool):Void {
        var base = Types.nonNull(value.type);
        switch base {
            case TString | TInt | TFloat | TBool | TUrl | TAny:
            case TSafeHtml if (inText):
            case TSafeHtml:
                error("unprintable-value", "SafeHtml cannot be written into an attribute",
                    value.position);
            case TDate:
                error("unprintable-value", "A date is written with a format", value.position,
                    "Format it with | date('long')");
            default:
                error("unprintable-value", '${Types.print(value.type)} cannot be written as text',
                    value.position, "Write one of its fields");
        }
    }

    function requireUrl(value:TypedExpr):Void {
        switch Types.nonNull(value.type) {
            case TString | TUrl | TAny:
            default:
                error("url-type",
                    'A URL attribute takes String or Url, not ${Types.print(value.type)}',
                    value.position);
        }
    }

    /** Style values come only from typed CSS filters or numbers (§8.1). **/
    function requireCss(value:TypedExpr):Void {
        switch value.kind {
            case FilterCall(_, filter, _) if (contract.isCssFilter(filter.name)):
                return;
            default:
        }
        if (Types.isNumber(Types.nonNull(value.type))) {
            return;
        }
        error("style-value", "Style values must come from the color, length or number filters",
            value.position, "Write {{ value | color }}");
    }

    function expression(expression:Expr, scope:Scope):Null<TypedExpr> {
        var checked = ExpressionChecker.check(expression, scope, contract);
        report(checked.diagnostics);
        if (checked.value != null) {
            markUsed(checked.value);
            if (headDepth > 0) {
                requireHeadScope(checked.value);
            }
        }
        return checked.value;
    }

    /** `<well:head>` reads props and sources only, so the head never depends on the body (§5.7). **/
    function requireHeadScope(value:TypedExpr):Void {
        walk(value, node -> {
            switch node.kind {
                case Name(name, Variable | Loop) if (!headLocals.exists(name)):
                    error("head-scope", '<well:head> cannot read the loop or slot value ${name}',
                        node.position);
                default:
            }
        });
    }

    function markUsed(value:TypedExpr):Void {
        walk(value, node -> {
            switch node.kind {
                case Name(name, Prop | Source):
                    used.set(name, true);
                default:
            }
        });
    }

    /** Visits every node of a typed expression. **/
    public static function walk(value:TypedExpr, visit:TypedExpr->Void):Void {
        visit(value);
        switch value.kind {
            case FieldAccess(target, _, _):
                walk(target, visit);
            case IndexAccess(target, key):
                walk(target, visit);
                walk(key, visit);
            case HelperCall(_, arguments) | SourceCall(_, arguments):
                for (argument in arguments) {
                    walk(argument.value, visit);
                }
            case FilterCall(target, _, arguments):
                walk(target, visit);
                for (argument in arguments) {
                    walk(argument.value, visit);
                }
            case ListValue(items):
                for (item in items) {
                    walk(item, visit);
                }
            case RecordValue(entries):
                for (entry in entries) {
                    walk(entry.value, visit);
                }
            case UnaryOp(_, operand):
                walk(operand, visit);
            case BinaryOp(_, left, right):
                walk(left, visit);
                walk(right, visit);
            case Choice(condition, consequent, alternative):
                walk(condition, visit);
                walk(consequent, visit);
                if (alternative != null) {
                    walk(alternative, visit);
                }
            case Constant(_) | Name(_, _) | Root(_):
        }
    }

    function report(found:Array<Diagnostic>):Void {
        for (diagnostic in found) {
            diagnostics.push(diagnostic);
        }
    }

    function error(code:String, message:String, position:Position, ?hint:String):Void {
        diagnostics.push(new Diagnostic(code, message, position, hint));
    }

    function warn(code:String, message:String, position:Position, ?hint:String):Void {
        diagnostics.push(new Diagnostic(code, message, position, hint, Warning));
    }
}
