package wellout.syntax;

import wellout.syntax.Ast;

using StringTools;

/**
    A compact one-line form of a document, for tests and debugging. Elements
    print as `(name attributes children)`, text as `"…"` with interpolation in
    braces, and whitespace-only text is left out.
**/
class AstPrinter {
    public static function print(document:Document):String {
        var lines:Array<String> = [];
        for (declaration in document.props) {
            lines.push('props ${declaration.name}=${declaration.value}');
        }
        for (declaration in document.sources) {
            lines.push('sources ${declaration.name}=${declaration.value}');
        }
        lines.push(nodes(document.children));
        return lines.join("\n");
    }

    static function nodes(list:Array<Node>):String {
        var printed:Array<String> = [];
        for (node in list) {
            var text = nodeText(node);
            if (text != "") {
                printed.push(text);
            }
        }
        return printed.join(" ");
    }

    static function nodeText(node:Node):String {
        return switch node {
            case Element(element):
                elementText(element);
            case Text(text):
                text.isWhitespace() ? "" : '"${partsText(text.parts).trim()}"';
            case Doctype(_, _):
                "<!doctype>";
        }
    }

    static function elementText(element:ElementNode):String {
        var output = new StringBuf();
        output.add('(${element.name}');
        for (attribute in element.attributes) {
            output.add(' ${attributeText(attribute)}');
        }
        var children = nodes(element.children);
        if (children != "") {
            output.add(' ${children}');
        }
        output.add(")");
        return output.toString();
    }

    static function attributeText(attribute:Attribute):String {
        return switch attribute.kind {
            case StaticValue(parts):
                '${attribute.name}="${partsText(parts)}"';
            case Present:
                attribute.name;
            case Binding(source, _):
                ':${attribute.name}={${source}}';
            case Directive(_, source, _):
                source == null ? attribute.name : '${attribute.name}={${source}}';
        }
    }

    static function partsText(parts:Array<TextPart>):String {
        var output = new StringBuf();
        var spaces = ~/\s+/g;
        for (part in parts) {
            switch part {
                case Literal(text):
                    output.add(spaces.replace(text, " "));
                case Interpolation(source, _):
                    output.add('{${source}}');
                case RawInterpolation(source, _):
                    output.add('{!!${source}!!}');
            }
        }
        return output.toString();
    }
}
