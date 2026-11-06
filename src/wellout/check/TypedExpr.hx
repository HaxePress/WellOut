package wellout.check;

import wellout.check.Scope.BindingKind;
import wellout.check.Types;
import wellout.syntax.Expr.BinaryOperator;
import wellout.syntax.Expr.UnaryOperator;
import wellout.syntax.Position;

/**
    A checked expression: every node carries its type, and names, fields,
    helpers and filters are resolved to the contract entries a backend
    reads or calls. A path becomes nested name, field and index nodes; a
    field or index read on a nullable target is null-safe (SPEC §4.4).
**/
class TypedExpr {
    public final kind:TypedKind;
    public final type:WellType;
    public final position:Position;

    public function new(kind:TypedKind, type:WellType, position:Position) {
        this.kind = kind;
        this.type = type;
        this.position = position;
    }
}

enum TypedKind {
    Constant(value:Constant);

    /** A prop, source, variable or `loop`. **/
    Name(name:String, binding:BindingKind);

    /** An implicit root such as `site`. **/
    Root(name:String);

    /** `target.field`; `view` is null for a record literal's field. **/
    FieldAccess(target:TypedExpr, view:Null<RecordType>, field:FieldInfo);

    /** `target[key]` on a list or map; the result is nullable because the entry may be missing. **/
    IndexAccess(target:TypedExpr, key:TypedExpr);

    HelperCall(helper:HelperSignature, arguments:Array<TypedArgument>);

    /** A `<sources>` call; its arguments are literals and context paths (SPEC §7.1). **/
    SourceCall(source:SourceSignature, arguments:Array<TypedArgument>);

    FilterCall(target:TypedExpr, filter:FilterSignature, arguments:Array<TypedArgument>);
    ListValue(items:Array<TypedExpr>);
    RecordValue(entries:Array<TypedEntry>);
    UnaryOp(operation:UnaryOperator, operand:TypedExpr);
    BinaryOp(operation:BinaryOperator, left:TypedExpr, right:TypedExpr);
    Choice(condition:TypedExpr, consequent:TypedExpr, alternative:Null<TypedExpr>);
}

enum Constant {
    CString(value:String);
    CInt(value:Int);
    CFloat(value:Float);
    CBool(value:Bool);
    CNull;
}

/** An argument matched to its parameter; `parameter` is null for an extra named argument. */
class TypedArgument {
    public final name:Null<String>;
    public final parameter:Null<Parameter>;
    public final value:TypedExpr;

    public function new(name:Null<String>, parameter:Null<Parameter>, value:TypedExpr) {
        this.name = name;
        this.parameter = parameter;
        this.value = value;
    }
}

class TypedEntry {
    public final name:String;
    public final value:TypedExpr;

    public function new(name:String, value:TypedExpr) {
        this.name = name;
        this.value = value;
    }
}
