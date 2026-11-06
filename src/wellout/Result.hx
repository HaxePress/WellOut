package wellout;

import wellout.syntax.Diagnostic;

/** A compile step's outcome: the value when the step succeeded, and every diagnostic found. */
class Result<T> {
    public final value:Null<T>;
    public final diagnostics:Array<Diagnostic>;

    public function new(value:Null<T>, diagnostics:Array<Diagnostic>) {
        this.value = value;
        this.diagnostics = diagnostics;
    }

    /** True when at least one diagnostic is an error; warnings alone leave a value usable. */
    public function hasErrors():Bool {
        for (diagnostic in diagnostics) {
            if (diagnostic.isError()) {
                return true;
            }
        }
        return false;
    }
}
