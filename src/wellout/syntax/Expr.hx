package wellout.syntax;

/** A parsed expression (SPEC §4.1) with the position of its first token. */
class Expr {
    public final kind:ExprKind;
    public final position:Position;

    public function new(kind:ExprKind, position:Position) {
        this.kind = kind;
        this.position = position;
    }
}

enum ExprKind {
    StringLiteral(value:String);
    IntLiteral(value:Int);
    FloatLiteral(value:Float);
    BoolLiteral(value:Bool);
    NullLiteral;

    /** A root name followed by field and index segments. Paths are null-safe (§4.4). **/
    Path(root:String, segments:Array<PathSegment>);

    /** A helper call (§4.5). **/
    Call(name:String, arguments:Array<Argument>);

    /** `target | name` or `target | name(arguments)`. **/
    Filter(target:Expr, name:String, arguments:Array<Argument>, namePosition:Position);

    ListLiteral(items:Array<Expr>);
    RecordLiteral(entries:Array<RecordEntry>);
    Unary(operation:UnaryOperator, operand:Expr);
    Binary(operation:BinaryOperator, left:Expr, right:Expr, operatorPosition:Position);

    /** `condition ? consequent` or `condition ? consequent : alternative`. **/
    Conditional(condition:Expr, consequent:Expr, alternative:Null<Expr>);
}

enum PathSegment {
    Field(name:String, position:Position);
    Index(key:Expr, position:Position);
}

enum UnaryOperator {
    Not;
    Negate;
}

enum BinaryOperator {
    Coalesce;
    Or;
    And;
    Equal;
    NotEqual;
    Less;
    LessOrEqual;
    Greater;
    GreaterOrEqual;
    In;
    Add;
    Subtract;
    Multiply;
    Divide;
    Modulo;
}

/** A call or filter argument; `name` is null for a positional argument. */
class Argument {
    public final name:Null<String>;
    public final value:Expr;
    public final position:Position;

    public function new(name:Null<String>, value:Expr, position:Position) {
        this.name = name;
        this.value = value;
        this.position = position;
    }
}

class RecordEntry {
    public final name:String;
    public final value:Expr;
    public final position:Position;

    public function new(name:String, value:Expr, position:Position) {
        this.name = name;
        this.value = value;
        this.position = position;
    }
}

/** `name in list` from a `:for` directive. */
class LoopSyntax {
    public final variable:String;
    public final variablePosition:Position;
    public final list:Expr;

    public function new(variable:String, variablePosition:Position, list:Expr) {
        this.variable = variable;
        this.variablePosition = variablePosition;
        this.list = list;
    }
}

/** A type as written in a declaration (§4.3), such as `List<ContentSummary>?`. */
class TypeSyntax {
    public final name:String;
    public final parameters:Array<TypeSyntax>;
    public final nullable:Bool;
    public final position:Position;

    public function new(name:String, parameters:Array<TypeSyntax>, nullable:Bool,
            position:Position) {
        this.name = name;
        this.parameters = parameters;
        this.nullable = nullable;
        this.position = position;
    }
}

/** `Type` or `Type = default` from a `<props>` attribute (§5.1). */
class PropSyntax {
    public final type:TypeSyntax;
    public final defaultValue:Null<Expr>;

    public function new(type:TypeSyntax, defaultValue:Null<Expr>) {
        this.type = type;
        this.defaultValue = defaultValue;
    }
}
