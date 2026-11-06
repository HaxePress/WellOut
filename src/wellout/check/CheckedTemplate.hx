package wellout.check;

import wellout.check.ComponentSignature;
import wellout.check.TypedExpr;
import wellout.check.Types;
import wellout.syntax.Position;

/**
    A checked template: declarations with their types, the signature it
    presents to callers, and a tree in which every expression is typed,
    every component call is matched to its signature, and control
    directives have become branch and repeat nodes. Backends compile this
    tree.
**/
class CheckedTemplate {
    public final name:String;
    public final props:Array<CheckedProp>;
    public final sources:Array<CheckedSource>;
    public final signature:ComponentSignature;
    public final nodes:Array<CheckedNode>;

    public function new(name:String, props:Array<CheckedProp>, sources:Array<CheckedSource>,
            signature:ComponentSignature, nodes:Array<CheckedNode>) {
        this.name = name;
        this.props = props;
        this.sources = sources;
        this.signature = signature;
        this.nodes = nodes;
    }
}

class CheckedProp {
    public final name:String;
    public final type:WellType;
    public final defaultValue:Null<TypedExpr>;
    public final position:Position;

    public function new(name:String, type:WellType, defaultValue:Null<TypedExpr>,
            position:Position) {
        this.name = name;
        this.type = type;
        this.defaultValue = defaultValue;
        this.position = position;
    }
}

/** A declared source: its name, its result type and the checked call that loads it. */
class CheckedSource {
    public final name:String;
    public final type:WellType;
    public final call:TypedExpr;
    public final position:Position;

    public function new(name:String, type:WellType, call:TypedExpr, position:Position) {
        this.name = name;
        this.type = type;
        this.call = call;
        this.position = position;
    }
}

enum CheckedNode {
    /** Template text; literal parts are markup source and are written as they are. **/
    Text(parts:Array<CheckedPart>);

    Doctype(text:String);
    Element(element:CheckedElement);
    Component(component:CheckedComponent);

    /** A `<slot>` outlet inside a component. **/
    SlotOutlet(outlet:CheckedSlotOutlet);

    /** An `:if`, `:else-if`, `:else` chain; an `:else` branch has no condition. **/
    Branches(branches:Array<CheckedBranch>);

    /** A `:for` element with its optional `:empty` sibling. **/
    Repeat(repeat:CheckedRepeat);

    /** A `<template>` grouping siblings without producing a tag. **/
    Group(children:Array<CheckedNode>);

    /** `<well:head>` content, rendered at the layout's `<HeadOutlet />`. **/
    Head(children:Array<CheckedNode>);

    HeadOutlet;
    Island(island:CheckedIsland);
    Asset(kind:AssetKind, path:String);
    Assets;
}

enum CheckedPart {
    Literal(text:String);
    Print(value:TypedExpr);
}

enum AssetKind {
    Css;
    Js;
}

enum AttributeValue {
    /** Quoted text with interpolation. **/
    Static(parts:Array<CheckedPart>);

    /** A bound value; null omits the attribute, and false omits a boolean attribute. **/
    Bound(value:TypedExpr);

    /** An attribute written without a value, such as `required`. **/
    Present;

    /** `class` and `:class` combined; falsy entries are dropped. **/
    Classes(parts:Array<CheckedPart>, bound:Null<TypedExpr>);
}

/** The output context of an attribute (SPEC §8.1), which decides validation and encoding. */
enum AttributeContext {
    Plain;
    Url;
    Srcset;
    Style;
    Boolean;
    ClassList;
}

class CheckedAttribute {
    public final name:String;
    public final value:AttributeValue;
    public final context:AttributeContext;

    public function new(name:String, value:AttributeValue, context:AttributeContext) {
        this.name = name;
        this.value = value;
        this.context = context;
    }
}

class CheckedElement {
    public final name:String;
    public final attributes:Array<CheckedAttribute>;
    public final children:Array<CheckedNode>;

    /** Void elements have no closing tag. **/
    public final isVoid:Bool;

    /** Raw-text elements (`<style>`, `<script>`) write their text unchanged. **/
    public final isRawText:Bool;

    /** The static fragment name (§9.1), or null. **/
    public final fragment:Null<String>;

    /** The `swap` target (§9.2), or null. **/
    public final swap:Null<AttributeValue>;

    /** Whether this element receives the caller's forwarded attributes (`:attrs`). **/
    public final forwardsAttributes:Bool;

    public final position:Position;

    public function new(name:String, attributes:Array<CheckedAttribute>,
            children:Array<CheckedNode>, isVoid:Bool, isRawText:Bool, fragment:Null<String>,
            swap:Null<AttributeValue>, forwardsAttributes:Bool, position:Position) {
        this.name = name;
        this.attributes = attributes;
        this.children = children;
        this.isVoid = isVoid;
        this.isRawText = isRawText;
        this.fragment = fragment;
        this.swap = swap;
        this.forwardsAttributes = forwardsAttributes;
        this.position = position;
    }

    public function attribute(name:String):Null<CheckedAttribute> {
        for (attribute in attributes) {
            if (attribute.name == name) {
                return attribute;
            }
        }
        return null;
    }
}

class CheckedBranch {
    public final condition:Null<TypedExpr>;
    public final node:CheckedNode;

    public function new(condition:Null<TypedExpr>, node:CheckedNode) {
        this.condition = condition;
        this.node = node;
    }
}

class CheckedRepeat {
    public final variable:String;
    public final list:TypedExpr;
    public final body:CheckedNode;
    public final empty:Null<CheckedNode>;
    public final position:Position;

    public function new(variable:String, list:TypedExpr, body:CheckedNode,
            empty:Null<CheckedNode>, position:Position) {
        this.variable = variable;
        this.list = list;
        this.body = body;
        this.empty = empty;
        this.position = position;
    }
}

class CheckedComponent {
    public final name:String;
    public final signature:ComponentSignature;
    public final props:Array<CheckedComponentProp>;

    /** Attributes forwarded to the component's `:attrs` element. **/
    public final forwarded:Array<CheckedAttribute>;

    public final slots:Array<CheckedSlotContent>;
    public final position:Position;

    public function new(name:String, signature:ComponentSignature,
            props:Array<CheckedComponentProp>, forwarded:Array<CheckedAttribute>,
            slots:Array<CheckedSlotContent>, position:Position) {
        this.name = name;
        this.signature = signature;
        this.props = props;
        this.forwarded = forwarded;
        this.slots = slots;
        this.position = position;
    }
}

class CheckedComponentProp {
    public final prop:PropSignature;
    public final value:AttributeValue;

    public function new(prop:PropSignature, value:AttributeValue) {
        this.prop = prop;
        this.value = value;
    }
}

/** Content a caller places in one slot; `variable` is the `:let` name receiving its value. */
class CheckedSlotContent {
    public final name:String;
    public final variable:Null<String>;
    public final children:Array<CheckedNode>;

    public function new(name:String, variable:Null<String>, children:Array<CheckedNode>) {
        this.name = name;
        this.variable = variable;
        this.children = children;
    }
}

class CheckedSlotOutlet {
    public final name:String;

    /** The value passed to the caller's `:let`, or null. **/
    public final exposes:Null<TypedExpr>;

    public final fallback:Array<CheckedNode>;

    public function new(name:String, exposes:Null<TypedExpr>, fallback:Array<CheckedNode>) {
        this.name = name;
        this.exposes = exposes;
        this.fallback = fallback;
    }
}

class CheckedIsland {
    public final signature:IslandSignature;
    public final props:Null<TypedExpr>;
    public final load:String;
    public final fallback:Array<CheckedNode>;

    public function new(signature:IslandSignature, props:Null<TypedExpr>, load:String,
            fallback:Array<CheckedNode>) {
        this.signature = signature;
        this.props = props;
        this.load = load;
        this.fallback = fallback;
    }
}
