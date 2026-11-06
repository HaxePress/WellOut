package wellout;

import haxe.io.Bytes;

/**
    A reusable UTF-8 output buffer.

    Static template markup is copied as pre-encoded bytes. Dynamic text is
    escaped while it is encoded, so writing allocates nothing once the buffer
    has reached its working size.
**/
class ByteWriter {
    /** Characters encoded per capacity check; bounds how far capacity is over-reserved. */
    static inline var BLOCK_CHARACTERS = 4096;

    /** The longest output of one character: `&quot;` and `&#039;` take six bytes. */
    static inline var MAX_BYTES_PER_CHARACTER = 6;

    public var bytes(default, null):Bytes;
    public var length(default, null):Int = 0;
    public var capacity(get, never):Int;

    public function new(capacity:Int = 8192) {
        bytes = Bytes.alloc(capacity < 16 ? 16 : capacity);
    }

    inline function get_capacity():Int {
        return bytes.length;
    }

    public inline function reset():Void {
        length = 0;
    }

    /** Copies pre-encoded bytes, such as the static markup of a template. */
    public function chunk(source:Bytes):Void {
        reserve(source.length);
        bytes.blit(length, source, 0, source.length);
        length += source.length;
    }

    /** Writes text escaped for HTML text and double- or single-quoted attribute values. */
    public function text(value:String):Void {
        write(value, true);
    }

    /** Writes text that a trusted producer has already made safe, without escaping. */
    public function trusted(value:String):Void {
        write(value, false);
    }

    /** Writes an integer as decimal digits without creating a string. */
    public function int(value:Int):Void {
        reserve(11);
        if (value == 0) {
            bytes.set(length++, "0".code);
            return;
        }
        if (value < 0) {
            bytes.set(length++, "-".code);
        }
        // Digits are taken from a non-positive value so that the minimum Int is exact.
        var remaining = value < 0 ? value : -value;
        var digits = 0;
        var probe = remaining;
        while (probe != 0) {
            probe = Std.int(probe / 10);
            digits++;
        }
        var end = length + digits;
        var position = end;
        while (remaining != 0) {
            var quotient = Std.int(remaining / 10);
            bytes.set(--position, "0".code + quotient * 10 - remaining);
            remaining = quotient;
        }
        length = end;
    }

    /** A standalone copy of the written bytes. It allocates, so render paths should not use it. */
    public function toBytes():Bytes {
        return bytes.sub(0, length);
    }

    public function toString():String {
        return bytes.getString(0, length);
    }

    function write(value:String, escape:Bool):Void {
        var count = value.length;
        var index = 0;
        while (index < count) {
            var end = index + BLOCK_CHARACTERS < count ? index + BLOCK_CHARACTERS : count;
            // One extra character covers a surrogate pair that ends just after the block.
            reserve((end - index + 1) * MAX_BYTES_PER_CHARACTER);
            index = encode(value, index, end, escape);
        }
    }

    /**
        Encodes `value` from `start` up to `end` and returns the next index. A
        surrogate pair that starts before `end` is completed past it.
    **/
    function encode(value:String, start:Int, end:Int, escape:Bool):Int {
        var target = bytes;
        var position = length;
        var count = value.length;
        var index = start;
        while (index < end) {
            var code = StringTools.fastCodeAt(value, index++);
            if (code < 0x80) {
                if (!escape) {
                    target.set(position++, code);
                    continue;
                }
                switch code {
                    case "&".code:
                        target.set(position, "&".code);
                        target.set(position + 1, "a".code);
                        target.set(position + 2, "m".code);
                        target.set(position + 3, "p".code);
                        target.set(position + 4, ";".code);
                        position += 5;
                    case "<".code:
                        target.set(position, "&".code);
                        target.set(position + 1, "l".code);
                        target.set(position + 2, "t".code);
                        target.set(position + 3, ";".code);
                        position += 4;
                    case ">".code:
                        target.set(position, "&".code);
                        target.set(position + 1, "g".code);
                        target.set(position + 2, "t".code);
                        target.set(position + 3, ";".code);
                        position += 4;
                    case '"'.code:
                        target.set(position, "&".code);
                        target.set(position + 1, "q".code);
                        target.set(position + 2, "u".code);
                        target.set(position + 3, "o".code);
                        target.set(position + 4, "t".code);
                        target.set(position + 5, ";".code);
                        position += 6;
                    case "'".code:
                        target.set(position, "&".code);
                        target.set(position + 1, "#".code);
                        target.set(position + 2, "0".code);
                        target.set(position + 3, "3".code);
                        target.set(position + 4, "9".code);
                        target.set(position + 5, ";".code);
                        position += 6;
                    default:
                        target.set(position++, code);
                }
            } else if (code < 0x800) {
                target.set(position++, 0xC0 | (code >> 6));
                target.set(position++, 0x80 | (code & 0x3F));
            } else if (code >= 0x10000) {
                // Targets with code-point strings return supplementary characters directly.
                position = encodeSupplementary(target, position, code);
            } else if (code >= 0xD800 && code <= 0xDBFF) {
                var low = index < count ? StringTools.fastCodeAt(value, index) : 0;
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    index++;
                    var point = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    position = encodeSupplementary(target, position, point);
                } else {
                    position = encodeReplacement(target, position);
                }
            } else if (code >= 0xDC00 && code <= 0xDFFF) {
                position = encodeReplacement(target, position);
            } else {
                target.set(position++, 0xE0 | (code >> 12));
                target.set(position++, 0x80 | ((code >> 6) & 0x3F));
                target.set(position++, 0x80 | (code & 0x3F));
            }
        }
        length = position;
        return index;
    }

    static inline function encodeSupplementary(target:Bytes, position:Int, point:Int):Int {
        target.set(position, 0xF0 | (point >> 18));
        target.set(position + 1, 0x80 | ((point >> 12) & 0x3F));
        target.set(position + 2, 0x80 | ((point >> 6) & 0x3F));
        target.set(position + 3, 0x80 | (point & 0x3F));
        return position + 4;
    }

    /** A lone surrogate cannot be encoded, so it becomes U+FFFD. */
    static inline function encodeReplacement(target:Bytes, position:Int):Int {
        target.set(position, 0xEF);
        target.set(position + 1, 0xBF);
        target.set(position + 2, 0xBD);
        return position + 3;
    }

    inline function reserve(extra:Int):Void {
        if (length + extra > bytes.length) {
            grow(length + extra);
        }
    }

    function grow(required:Int):Void {
        var next = bytes.length * 2;
        while (next < required) {
            next *= 2;
        }
        var larger = Bytes.alloc(next);
        larger.blit(0, bytes, 0, length);
        bytes = larger;
    }
}
