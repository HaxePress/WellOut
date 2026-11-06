#if jvm
import haxe.Int64;

/** The JDK management bean, needed only as the declared return type. */
@:native("java.lang.management.ThreadMXBean")
extern interface PlatformThreads {}

@:native("java.lang.management.ManagementFactory")
extern class ManagementFactory {
    static function getThreadMXBean():PlatformThreads;
}

/** HotSpot's extension that reports bytes allocated by the current thread. */
@:native("com.sun.management.ThreadMXBean")
extern interface AllocationCounter extends PlatformThreads {
    function getCurrentThreadAllocatedBytes():Int64;
}
#end
