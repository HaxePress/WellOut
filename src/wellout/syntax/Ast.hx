package wellout.syntax;

/** A parsed template: its declarations and its top-level markup. */
class Document {
    public final props:Array<Declaration>;
    public final sources:Array<Declaration>;
    public final children:Array<Node>;

    public function new(props:Array<Declaration>, sources:Array<Declaration>,
            children:Array<Node>) {
        this.props = props;
        this.sources = sources;
        this.children = children;
    }
}

/** One `<props>` or `<sources>` attribute: a name and its unparsed type or source call. */
class Declaration {
    public final name:String;
    public final value:String;
    public final position:Position;
    public final valuePosition:Position;

    public function new(name:String, value:String, position:Position, valuePosition:Position) {
        this.name = name;
        this.value = value;
        this.position = position;
        this.valuePosition = valuePosition;
    }
}

enum Node {
    Element(element:ElementNode);
    Text(text:TextNode);
    Doctype(text:String, position:Position);
}

enum ElementKind {
    HtmlElement;
    VoidElement;
    RawTextElement;
    ComponentElement;
    TemplateElement;
    SlotElement;
    PropsDeclaration;
    SourcesDeclaration;
}

class ElementNode {
    public final name:String;
    public final kind:ElementKind;
    public final attributes:Array<Attribute>;
    public final children:Array<Node>;
    public final position:Position;
    public final selfClosing:Bool;

    public function new(name:String, kind:ElementKind, attributes:Array<Attribute>,
            children:Array<Node>, position:Position, selfClosing:Bool) {
        this.name = name;
        this.kind = kind;
        this.attributes = attributes;
        this.children = children;
        this.position = position;
        this.selfClosing = selfClosing;
    }

    public function directive(kind:DirectiveKind):Null<Attribute> {
        for (attribute in attributes) {
            switch attribute.kind {
                case Directive(found, _, _) if (found == kind):
                    return attribute;
                default:
            }
        }
        return null;
    }
}

class TextNode {
    public final parts:Array<TextPart>;
    public final position:Position;

    public function new(parts:Array<TextPart>, position:Position) {
        this.parts = parts;
        this.position = position;
    }

    public function isWhitespace():Bool {
        for (part in parts) {
            switch part {
                case Literal(text):
                    if (StringTools.trim(text) != "") {
                        return false;
                    }
                case Interpolation(_, _):
                    return false;
            }
        }
        return true;
    }
}

enum TextPart {
    Literal(text:String);
    Interpolation(source:String, position:Position);
}

class Attribute {
    public final name:String;
    public final kind:AttributeKind;
    public final position:Position;

    /** Where the quoted value starts, or null for an attribute without a value. **/
    public final valuePosition:Null<Position>;

    public function new(name:String, kind:AttributeKind, position:Position,
            ?valuePosition:Position) {
        this.name = name;
        this.kind = kind;
        this.position = position;
        this.valuePosition = valuePosition;
    }
}

enum AttributeKind {
    /** A value written in quotes; it may contain interpolation. **/
    StaticValue(parts:Array<TextPart>);

    /** An attribute written without a value, such as `required`. **/
    Present;

    /**
        `:name="expression"`: a typed value for an attribute or a component
        prop. The source is trimmed and the position is that of its first
        character, so expression diagnostics point into the template.
    **/
    Binding(source:String, expressionPosition:Position);

    /** A directive with its trimmed value, or null fields for one written without a value. **/
    Directive(kind:DirectiveKind, source:Null<String>, expressionPosition:Null<Position>);
}

enum DirectiveKind {
    If;
    ElseIf;
    Else;
    For;
    Empty;
    Let;
    Attrs;
    Verbatim;
}
