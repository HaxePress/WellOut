import haxe.io.Bytes;
import wellout.ByteWriter;
import wellout.WriterPool;
#if jvm
import haxe.Int64;
import JvmAllocation.AllocationCounter;
import JvmAllocation.ManagementFactory;
#end

class Main {
    static var checks = 0;
    static var failures = 0;

    static function main() {
        escapesHtmlText();
        writesTrustedTextUnchanged();
        encodesUtf8();
        encodesSurrogatePairs();
        replacesLoneSurrogates();
        writesIntegers();
        copiesChunks();
        growsAcrossBlocks();
        poolReusesWriters();
        poolBoundsRetainedWriters();
        ParserTest.run(check);
        ExpressionTest.run(check);
        #if jvm
        rendersWithoutAllocating();
        #end
        var passed = checks - failures;
        Sys.println('${passed}/${checks} checks passed');
        Sys.exit(failures == 0 ? 0 : 1);
    }

    static function check(condition:Bool, message:String):Void {
        checks++;
        if (!condition) {
            failures++;
            Sys.println('FAIL ${message}');
        }
    }

    static function escapesHtmlText():Void {
        var source = "Tom & Jerry <b>\"quoted\"</b> it's";
        var writer = new ByteWriter(16);
        writer.text(source);
        check(writer.toString() == StringTools.htmlEscape(source, true),
            "text escapes ampersands, angle brackets and both quotes");
    }

    static function writesTrustedTextUnchanged():Void {
        var source = "<p class=\"lead\">Already safe &amp; rendered</p>";
        var writer = new ByteWriter(16);
        writer.trusted(source);
        check(writer.toString() == source, "trusted text is written without escaping");
    }

    static function encodesUtf8():Void {
        var source = "İstanbul — ğüşöç ½ €";
        var writer = new ByteWriter(16);
        writer.text(source);
        check(writer.toBytes().compare(Bytes.ofString(source)) == 0,
            "two- and three-byte characters are encoded as UTF-8");
    }

    static function encodesSurrogatePairs():Void {
        var source = "a😀b🎉c";
        var writer = new ByteWriter(16);
        writer.text(source);
        check(writer.toBytes().compare(Bytes.ofString(source)) == 0,
            "supplementary characters are encoded as four-byte UTF-8");
    }

    static function replacesLoneSurrogates():Void {
        #if (target.utf16)
        var source = 'x${String.fromCharCode(0xD800)}y${String.fromCharCode(0xDC00)}';
        var writer = new ByteWriter(16);
        writer.text(source);
        var expected = Bytes.alloc(8);
        var values = [0x78, 0xEF, 0xBF, 0xBD, 0x79, 0xEF, 0xBF, 0xBD];
        for (index in 0...values.length) {
            expected.set(index, values[index]);
        }
        check(writer.toBytes().compare(expected) == 0, "lone surrogates become U+FFFD");
        #end
    }

    static function writesIntegers():Void {
        var values = [0, 7, -7, 42, 123456789, -2147483648, 2147483647];
        for (value in values) {
            var writer = new ByteWriter(16);
            writer.int(value);
            check(writer.toString() == Std.string(value), 'integer ${value} is written as digits');
        }
    }

    static function copiesChunks():Void {
        var open = Bytes.ofString("<p>");
        var close = Bytes.ofString("</p>");
        var writer = new ByteWriter(16);
        writer.chunk(open);
        writer.text("a&b");
        writer.chunk(close);
        check(writer.toString() == "<p>a&amp;b</p>", "chunks are copied around escaped text");
    }

    static function growsAcrossBlocks():Void {
        var builder = new StringBuf();
        for (index in 0...4095) {
            builder.add(index % 97 == 0 ? "&" : "x");
        }
        // The pair starts at index 4095, so it straddles the first encoding block.
        builder.add("😀");
        for (index in 0...3000) {
            builder.add(index % 89 == 0 ? "<" : "y");
        }
        var source = builder.toString();
        var writer = new ByteWriter(16);
        writer.text(source);
        var expected = Bytes.ofString(StringTools.htmlEscape(source, true));
        check(writer.toBytes().compare(expected) == 0,
            "long text grows the buffer and keeps a surrogate pair across a block boundary");
        check(writer.capacity < expected.length * 2 + 64 * 1024,
            "capacity grows close to the written size");
    }

    static function poolReusesWriters():Void {
        var pool = new WriterPool(2, 64, 1024);
        var first = pool.acquire();
        first.text("abc");
        pool.release(first);
        var second = pool.acquire();
        check(second == first, "the pool hands out a released writer again");
        check(second.length == 0, "a reused writer starts empty");
    }

    static function poolBoundsRetainedWriters():Void {
        var pool = new WriterPool(2, 64, 1024);
        var large = pool.acquire();
        large.text(StringTools.lpad("", "x", 5000));
        pool.release(large);
        check(pool.retained == 0, "a writer that outgrew the limit is dropped");
        pool.release(new ByteWriter(64));
        pool.release(new ByteWriter(64));
        pool.release(new ByteWriter(64));
        check(pool.retained == 2, "the pool keeps at most its configured number of writers");
    }

    #if jvm
    static function rendersWithoutAllocating():Void {
        var counter:AllocationCounter = cast ManagementFactory.getThreadMXBean();
        var writer = new ByteWriter(64);
        var open = Bytes.ofString('<li class="item">');
        var close = Bytes.ofString("</li>");
        var titles = ["Tom & Jerry <3>", "İstanbul — ğüşöç", "a😀b \"quoted\" it's"];
        for (round in 0...20000) {
            renderList(writer, open, close, titles);
        }
        var renders = 10000;
        var before = counter.getCurrentThreadAllocatedBytes();
        for (round in 0...renders) {
            renderList(writer, open, close, titles);
        }
        var allocated = Int64.toInt(counter.getCurrentThreadAllocatedBytes() - before);
        Sys.println('steady-state allocation: ${allocated} bytes in ${renders} renders');
        check(allocated < renders,
            'steady-state rendering allocates nothing (${allocated} bytes in ${renders} renders)');
    }

    static function renderList(writer:ByteWriter, open:Bytes, close:Bytes,
            titles:Array<String>):Void {
        writer.reset();
        for (index in 0...titles.length) {
            writer.chunk(open);
            writer.text(titles[index]);
            writer.int(index * 1000 - 3);
            writer.chunk(close);
        }
    }
    #end
}
