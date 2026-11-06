package wellout.syntax;

using StringTools;

enum Severity {
    Error;
    Warning;
}

/** A compile problem with a stable code, a message, its position and an optional hint. */
class Diagnostic {
    public final code:String;
    public final message:String;
    public final position:Position;
    public final hint:Null<String>;
    public final severity:Severity;

    public function new(code:String, message:String, position:Position, ?hint:String,
            ?severity:Severity) {
        this.code = code;
        this.message = message;
        this.position = position;
        this.hint = hint;
        this.severity = severity == null ? Error : severity;
    }

    public function isError():Bool {
        return severity == Error;
    }

    /** `file:line:column: message`, the source line and a caret under the column. */
    public function format(source:String, file:String):String {
        var lines = source.split("\n");
        var text = position.line - 1 < lines.length ? lines[position.line - 1] : "";
        var caret = "".lpad(" ", position.column - 1);
        var label = severity == Warning ? "warning: " : "";
        var output = new StringBuf();
        output.add('${file}:${position.line}:${position.column}: ${label}${message} [${code}]\n');
        output.add('    ${text}\n');
        output.add('    ${caret}^');
        if (hint != null) {
            output.add('\n    hint: ${hint}');
        }
        return output.toString();
    }
}
