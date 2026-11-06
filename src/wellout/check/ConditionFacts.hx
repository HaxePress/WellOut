package wellout.check;

import wellout.syntax.Expr;

/**
    What holds when a condition is truthy: the paths that are non-null and
    the capabilities that `can()` confirmed. A truthy path makes every
    prefix non-null too, because a null segment yields null (SPEC §4.4).
    Facts come from the condition itself, from the operands of `and`, from
    `path != null` and from `can('capability')`.
**/
class ConditionFacts {
    public final nonNullPaths:Array<String> = [];
    public final capabilities:Array<String> = [];

    function new() {}

    public static function of(condition:Expr):ConditionFacts {
        var facts = new ConditionFacts();
        facts.collect(condition);
        return facts;
    }

    public function applyTo(scope:Scope):Void {
        for (key in nonNullPaths) {
            scope.narrow(key);
        }
        for (capability in capabilities) {
            scope.guard(capability);
        }
    }

    /** The scope key of a path with static segments, such as `post.tags[0].url`, or null. **/
    public static function pathKey(expression:Expr):Null<String> {
        return switch expression.kind {
            case Path(root, segments):
                var key = root;
                for (segment in segments) {
                    key = extend(key, segment);
                    if (key == null) {
                        return null;
                    }
                }
                key;
            default:
                null;
        }
    }

    /** `key` extended by one segment, or null when the segment is computed. **/
    public static function extend(key:Null<String>, segment:PathSegment):Null<String> {
        if (key == null) {
            return null;
        }
        return switch segment {
            case Field(name, _):
                '${key}.${name}';
            case Index({kind: IntLiteral(value)}, _):
                '${key}[${value}]';
            case Index({kind: StringLiteral(value)}, _):
                '${key}[\'${value}\']';
            case Index(_, _):
                null;
        }
    }

    function collect(condition:Expr):Void {
        switch condition.kind {
            case Path(_, _):
                addPath(condition);
            case Binary(And, left, right, _):
                collect(left);
                collect(right);
            case Binary(NotEqual, left, {kind: NullLiteral}, _):
                addPath(left);
            case Binary(NotEqual, {kind: NullLiteral}, right, _):
                addPath(right);
            case Call("can", [{name: null, value: {kind: StringLiteral(capability)}}]):
                capabilities.push(capability);
            default:
        }
    }

    function addPath(expression:Expr):Void {
        switch expression.kind {
            case Path(root, segments):
                var key = root;
                nonNullPaths.push(key);
                for (segment in segments) {
                    key = extend(key, segment);
                    if (key == null) {
                        return;
                    }
                    nonNullPaths.push(key);
                }
            default:
        }
    }
}
