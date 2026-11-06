package wellout.syntax;

import wellout.syntax.Expr;

/**
    A fully parenthesized one-line form of an expression, for tests and
    debugging. Every operator application prints inside parentheses, so the
    output shows precedence and associativity.
**/
class ExprPrinter {
    public static function print(expression:Expr):String {
        return switch expression.kind {
            case StringLiteral(value):
                '\'${escape(value)}\'';
            case IntLiteral(value):
                Std.string(value);
            case FloatLiteral(value):
                decimal(value);
            case BoolLiteral(value):
                value ? "true" : "false";
            case NullLiteral:
                "null";
            case Path(root, segments):
                root + segmentsText(segments);
            case Call(name, arguments):
                '${name}(${argumentsText(arguments)})';
            case Filter(target, name, arguments, _):
                var call = arguments.length == 0 ? name : '${name}(${argumentsText(arguments)})';
                '(${print(target)} | ${call})';
            case ListLiteral(items):
                var printed = [for (item in items) print(item)];
                '[${printed.join(", ")}]';
            case RecordLiteral(entries):
                var printed = [for (entry in entries) '${entry.name}: ${print(entry.value)}'];
                entries.length == 0 ? "{}" : '{ ${printed.join(", ")} }';
            case Unary(Not, operand):
                '(not ${print(operand)})';
            case Unary(Negate, operand):
                '(-${print(operand)})';
            case Binary(operation, left, right, _):
                '(${print(left)} ${operatorText(operation)} ${print(right)})';
            case Conditional(condition, consequent, null):
                '(${print(condition)} ? ${print(consequent)})';
            case Conditional(condition, consequent, alternative):
                '(${print(condition)} ? ${print(consequent)} : ${print(alternative)})';
        }
    }

    public static function printLoop(loop:LoopSyntax):String {
        return '${loop.variable} in ${print(loop.list)}';
    }

    public static function printType(type:TypeSyntax):String {
        var output = type.name;
        if (type.parameters.length > 0) {
            var printed = [for (parameter in type.parameters) printType(parameter)];
            output += '<${printed.join(", ")}>';
        }
        return type.nullable ? '${output}?' : output;
    }

    public static function printProp(prop:PropSyntax):String {
        var type = printType(prop.type);
        return prop.defaultValue == null ? type : '${type} = ${print(prop.defaultValue)}';
    }

    static function segmentsText(segments:Array<PathSegment>):String {
        var output = new StringBuf();
        for (segment in segments) {
            switch segment {
                case Field(name, _):
                    output.add('.${name}');
                case Index(key, _):
                    output.add('[${print(key)}]');
            }
        }
        return output.toString();
    }

    static function argumentsText(arguments:Array<Argument>):String {
        var printed = [for (argument in arguments) argumentText(argument)];
        return printed.join(", ");
    }

    static function argumentText(argument:Argument):String {
        var value = print(argument.value);
        return argument.name == null ? value : '${argument.name}: ${value}';
    }

    static function operatorText(operation:BinaryOperator):String {
        return switch operation {
            case Coalesce: "??";
            case Or: "or";
            case And: "and";
            case Equal: "==";
            case NotEqual: "!=";
            case Less: "<";
            case LessOrEqual: "<=";
            case Greater: ">";
            case GreaterOrEqual: ">=";
            case In: "in";
            case Add: "+";
            case Subtract: "-";
            case Multiply: "*";
            case Divide: "/";
            case Modulo: "%";
        }
    }

    static function decimal(value:Float):String {
        var text = Std.string(value);
        return text.indexOf(".") < 0 && text.indexOf("e") < 0 ? '${text}.0' : text;
    }

    static function escape(value:String):String {
        var escaped = StringTools.replace(value, "\\", "\\\\");
        escaped = StringTools.replace(escaped, "'", "\\'");
        escaped = StringTools.replace(escaped, "\n", "\\n");
        escaped = StringTools.replace(escaped, "\t", "\\t");
        return StringTools.replace(escaped, "\r", "\\r");
    }
}
