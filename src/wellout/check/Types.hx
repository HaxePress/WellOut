package wellout.check;

import wellout.syntax.Diagnostic;
import wellout.syntax.Expr.TypeSyntax;

/** A template type (SPEC §4.3). */
enum WellType {
    TString;
    TInt;
    TFloat;
    TBool;
    TDate;
    TUrl;
    TSafeHtml;
    TFragment;
    TList(item:WellType);

    /** `Map<String, value>`; keys are always strings. **/
    TMap(value:WellType);

    TNullable(inner:WellType);

    /** A host view type (§6.1), looked up by name in the contract. **/
    TView(name:String);

    /** The type of a record literal such as `{ list: 'main' }`. **/
    TRecord(fields:Array<FieldInfo>);

    /** A type parameter in a helper or filter signature, bound per call. **/
    TParameter(name:String);

    /** Unknown, such as the item type of `[]`; it unifies with every type. **/
    TAny;
}

/** A readable field of a view type or record literal. */
class FieldInfo {
    public final name:String;
    public final type:WellType;

    /** The capability a viewer needs for this field (`@:well.requires`), or null. **/
    public final requires:Null<String>;

    public function new(name:String, type:WellType, ?requires:String) {
        this.name = name;
        this.type = type;
        this.requires = requires;
    }
}

/** A host view type: the fields templates may read (§6.2). */
class RecordType {
    public final name:String;
    public final fields:Array<FieldInfo>;

    public function new(name:String, fields:Array<FieldInfo>) {
        this.name = name;
        this.fields = fields;
    }

    public function field(name:String):Null<FieldInfo> {
        for (field in fields) {
            if (field.name == name) {
                return field;
            }
        }
        return null;
    }

    public function fieldNames():Array<String> {
        return [for (field in fields) field.name];
    }
}

class Parameter {
    public final name:String;
    public final type:WellType;
    public final optional:Bool;

    public function new(name:String, type:WellType, optional:Bool = false) {
        this.name = name;
        this.type = type;
        this.optional = optional;
    }
}

/** A host helper such as `t` or `route` (§4.5). */
class HelperSignature {
    public final name:String;
    public final parameters:Array<Parameter>;
    public final returnType:WellType;

    /** Whether extra named arguments are accepted, as in `t(key, name: value)`. **/
    public final acceptsNamedRest:Bool;

    public function new(name:String, parameters:Array<Parameter>, returnType:WellType,
            acceptsNamedRest:Bool = false) {
        this.name = name;
        this.parameters = parameters;
        this.returnType = returnType;
        this.acceptsNamedRest = acceptsNamedRest;
    }
}

/** A filter: its input type, its arguments and its result (§4.5). */
class FilterSignature {
    public final name:String;
    public final input:WellType;
    public final parameters:Array<Parameter>;
    public final returnType:WellType;

    public function new(name:String, input:WellType, parameters:Array<Parameter>,
            returnType:WellType) {
        this.name = name;
        this.input = input;
        this.parameters = parameters;
        this.returnType = returnType;
    }
}

/** A source function (SPEC §7.1): bounded data loading that a template declares by name. */
class SourceSignature {
    public final name:String;
    public final parameters:Array<Parameter>;
    public final returnType:WellType;

    public function new(name:String, parameters:Array<Parameter>, returnType:WellType) {
        this.name = name;
        this.parameters = parameters;
        this.returnType = returnType;
    }
}

/** A client module mounted into server-rendered markup (§9.3), with its typed props. */
class IslandSignature {
    public final name:String;

    /** The props type; a record or view type, or `{}` for an island without props. **/
    public final props:WellType;

    /** Translation keys the island needs in the browser; only these reach it (§10). **/
    public final translationKeys:Array<String>;

    public function new(name:String, props:WellType, ?translationKeys:Array<String>) {
        this.name = name;
        this.props = props;
        this.translationKeys = translationKeys == null ? [] : translationKeys;
    }
}

/** Operations on types: printing, nullability, unification, assignability and resolution. */
class Types {
    static final scalars:Map<String, WellType> = [
        "String" => TString,
        "Int" => TInt,
        "Float" => TFloat,
        "Bool" => TBool,
        "Date" => TDate,
        "Url" => TUrl,
        "SafeHtml" => TSafeHtml,
        "Fragment" => TFragment,
        "Any" => TAny
    ];
    static final builtinNames = [
        "String",
        "Int",
        "Float",
        "Bool",
        "Date",
        "Url",
        "SafeHtml",
        "Fragment",
        "List",
        "Map",
        "Any"
    ];

    public static function print(type:WellType):String {
        return switch type {
            case TString: "String";
            case TInt: "Int";
            case TFloat: "Float";
            case TBool: "Bool";
            case TDate: "Date";
            case TUrl: "Url";
            case TSafeHtml: "SafeHtml";
            case TFragment: "Fragment";
            case TList(item): 'List<${print(item)}>';
            case TMap(value): 'Map<String, ${print(value)}>';
            case TNullable(TAny): "null";
            case TNullable(inner): '${print(inner)}?';
            case TView(name): name;
            case TRecord([]): "{}";
            case TRecord(fields):
                var printed = [for (field in fields) '${field.name}: ${print(field.type)}'];
                '{ ${printed.join(", ")} }';
            case TParameter(name): name;
            case TAny: "unknown";
        }
    }

    public static function isNullable(type:WellType):Bool {
        return type.match(TNullable(_));
    }

    public static function nonNull(type:WellType):WellType {
        return switch type {
            case TNullable(inner): inner;
            default: type;
        }
    }

    public static function nullable(type:WellType):WellType {
        return isNullable(type) ? type : TNullable(type);
    }

    public static function isNumber(type:WellType):Bool {
        return type == TInt || type == TFloat;
    }

    /** Structural equality. **/
    public static function same(a:WellType, b:WellType):Bool {
        return switch [a, b] {
            case [TList(x), TList(y)]: same(x, y);
            case [TMap(x), TMap(y)]: same(x, y);
            case [TNullable(x), TNullable(y)]: same(x, y);
            case [TView(x), TView(y)]: x == y;
            case [TParameter(x), TParameter(y)]: x == y;
            case [TRecord(x), TRecord(y)]: sameFields(x, y);
            default: Type.enumIndex(a) == Type.enumIndex(b) && Type.enumParameters(a)
                    .length == 0;
        }
    }

    static function sameFields(x:Array<FieldInfo>, y:Array<FieldInfo>):Bool {
        if (x.length != y.length) {
            return false;
        }
        for (field in x) {
            var other = find(y, field.name);
            if (other == null || !same(field.type, other.type)) {
                return false;
            }
        }
        return true;
    }

    static function find(fields:Array<FieldInfo>, name:String):Null<FieldInfo> {
        for (field in fields) {
            if (field.name == name) {
                return field;
            }
        }
        return null;
    }

    /**
        The common type of two values, such as the branches of a conditional:
        `Int` and `Float` join to `Float`, `unknown` takes the other type, and
        the result is nullable when either side is. Null when there is none.
    **/
    public static function unify(a:WellType, b:WellType):Null<WellType> {
        var joined = unifyNonNull(nonNull(a), nonNull(b));
        if (joined == null) {
            return null;
        }
        return isNullable(a) || isNullable(b) ? nullable(joined) : joined;
    }

    static function unifyNonNull(a:WellType, b:WellType):Null<WellType> {
        if (a == TAny) {
            return b;
        }
        if (b == TAny) {
            return a;
        }
        return switch [a, b] {
            case [TInt, TFloat] | [TFloat, TInt]:
                TFloat;
            case [TUrl, TString] | [TString, TUrl]:
                TString;
            case [TList(x), TList(y)]:
                var item = unify(x, y);
                item == null ? null : TList(item);
            case [TMap(x), TMap(y)]:
                var value = unify(x, y);
                value == null ? null : TMap(value);
            case [TRecord(x), TRecord(y)]:
                unifyRecords(x, y);
            default:
                same(a, b) ? a : null;
        }
    }

    static function unifyRecords(x:Array<FieldInfo>, y:Array<FieldInfo>):Null<WellType> {
        if (x.length != y.length) {
            return null;
        }
        var fields:Array<FieldInfo> = [];
        for (field in x) {
            var other = find(y, field.name);
            if (other == null) {
                return null;
            }
            var type = unify(field.type, other.type);
            if (type == null) {
                return null;
            }
            fields.push(new FieldInfo(field.name, type));
        }
        return TRecord(fields);
    }

    /**
        Whether a value of type `value` can be passed where `expected` is
        declared. `Int` widens to `Float`, a non-null value fits a nullable
        slot, and type parameters in `expected` are bound in `bindings`.
    **/
    public static function assignable(value:WellType, expected:WellType,
            bindings:Map<String, WellType>):Bool {
        switch expected {
            case TAny:
                return true;
            case TNullable(inner):
                return assignable(nonNull(value), inner, bindings);
            case TParameter(name):
                if (isNullable(value)) {
                    return false;
                }
                var bound = bindings.get(name);
                if (bound == null) {
                    bindings.set(name, value);
                    return true;
                }
                var joined = unify(bound, value);
                if (joined == null) {
                    return false;
                }
                bindings.set(name, joined);
                return true;
            default:
        }
        if (isNullable(value)) {
            return false;
        }
        return switch [value, expected] {
            case [TAny, _]: true;
            case [TInt, TFloat]: true;
            // A URL is text, and text written into a URL attribute is checked there.
            case [TUrl, TString] | [TString, TUrl]: true;
            case [TList(a), TList(b)]: assignable(a, b, bindings);
            case [TMap(a), TMap(b)]: assignable(a, b, bindings);
            case [TRecord(a), TRecord(b)]: assignableFields(a, b, bindings);
            default: same(value, expected);
        }
    }

    static function assignableFields(value:Array<FieldInfo>, expected:Array<FieldInfo>,
            bindings:Map<String, WellType>):Bool {
        if (value.length != expected.length) {
            return false;
        }
        for (field in expected) {
            var given = find(value, field.name);
            if (given == null || !assignable(given.type, field.type, bindings)) {
                return false;
            }
        }
        return true;
    }

    /** Replaces bound type parameters; an unbound parameter becomes `unknown`. **/
    public static function substitute(type:WellType, bindings:Map<String, WellType>):WellType {
        return switch type {
            case TParameter(name):
                var bound = bindings.get(name);
                bound == null ? TAny : bound;
            case TList(item):
                TList(substitute(item, bindings));
            case TMap(value):
                TMap(substitute(value, bindings));
            case TNullable(inner):
                nullable(substitute(inner, bindings));
            case TRecord(fields):
                TRecord([
                    for (field in fields)
                        new FieldInfo(field.name, substitute(field.type, bindings), field.requires)
                ]);
            default:
                type;
        }
    }

    /**
        Resolves a declared type against the host contract. Problems are
        reported into `diagnostics` and yield null.
    **/
    public static function resolve(syntax:TypeSyntax, contract:HostContract,
            diagnostics:Array<Diagnostic>):Null<WellType> {
        var resolved = resolveNamed(syntax, contract, diagnostics);
        if (resolved == null) {
            return null;
        }
        return syntax.nullable ? TNullable(resolved) : resolved;
    }

    static function resolveNamed(syntax:TypeSyntax, contract:HostContract,
            diagnostics:Array<Diagnostic>):Null<WellType> {
        var count = syntax.parameters.length;
        switch syntax.name {
            case "List":
                if (count != 1) {
                    diagnostics.push(new Diagnostic("type-parameters",
                        "List takes one type parameter", syntax.position, "Write List<Item>"));
                    return null;
                }
                var item = resolve(syntax.parameters[0], contract, diagnostics);
                return item == null ? null : TList(item);
            case "Map":
                if (count != 2) {
                    diagnostics.push(new Diagnostic("type-parameters",
                        "Map takes two type parameters", syntax.position,
                        "Write Map<String, Value>"));
                    return null;
                }
                var key = syntax.parameters[0];
                if (key.name != "String" || key.parameters.length > 0 || key.nullable) {
                    diagnostics.push(new Diagnostic("map-key-type", "Map keys are always String",
                        key.position, "Write Map<String, Value>"));
                    return null;
                }
                var value = resolve(syntax.parameters[1], contract, diagnostics);
                return value == null ? null : TMap(value);
            default:
                if (count > 0) {
                    diagnostics.push(new Diagnostic("type-parameters",
                        '${syntax.name} takes no type parameters', syntax.position));
                    return null;
                }
                var scalar = scalars.get(syntax.name);
                if (scalar != null) {
                    return scalar;
                }
                if (contract.viewType(syntax.name) != null) {
                    return TView(syntax.name);
                }
                var candidates = builtinNames.concat(contract.viewNames());
                diagnostics.push(new Diagnostic("unknown-type", 'Unknown type ${syntax.name}',
                    syntax.position, Suggestions.hint(syntax.name, candidates)));
                return null;
        }
    }
}
