package wellout.syntax;

/** A place in template source: a zero-based offset with its one-based line and column. */
class Position {
    public final offset:Int;
    public final line:Int;
    public final column:Int;

    public function new(offset:Int, line:Int, column:Int) {
        this.offset = offset;
        this.line = line;
        this.column = column;
    }

    public function toString():String {
        return '${line}:${column}';
    }
}
