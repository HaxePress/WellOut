package wellout;

#if (target.threaded)
import sys.thread.Mutex;
#end

/**
    A bounded, thread-safe pool of writers.

    A writer goes back to the pool only after its bytes are no longer needed,
    for example once the HTTP driver has finished writing them. Writers that
    grew beyond `maxCapacity` are dropped so one large page does not keep a
    large buffer alive.
**/
class WriterPool {
    final available:Array<ByteWriter> = [];
    final maxRetained:Int;
    final initialCapacity:Int;
    final maxCapacity:Int;
    #if (target.threaded)
    final lock = new Mutex();
    #end

    public var retained(get, never):Int;

    public function new(maxRetained:Int = 64, initialCapacity:Int = 8192,
            maxCapacity:Int = 1048576) {
        this.maxRetained = maxRetained;
        this.initialCapacity = initialCapacity;
        this.maxCapacity = maxCapacity;
    }

    public function acquire():ByteWriter {
        enter();
        var writer = available.pop();
        leave();
        if (writer == null) {
            return new ByteWriter(initialCapacity);
        }
        writer.reset();
        return writer;
    }

    public function release(writer:ByteWriter):Void {
        if (writer.capacity > maxCapacity) {
            return;
        }
        enter();
        if (available.length < maxRetained) {
            available.push(writer);
        }
        leave();
    }

    function get_retained():Int {
        enter();
        var count = available.length;
        leave();
        return count;
    }

    inline function enter():Void {
        #if (target.threaded)
        lock.acquire();
        #end
    }

    inline function leave():Void {
        #if (target.threaded)
        lock.release();
        #end
    }
}
