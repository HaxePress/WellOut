package wellout.render;

#if php
import haxe.crypto.Md5;
import php.Global;
import php.Lib;
import php.Syntax;

/**
    Keeps compiled templates as PHP files, as Laravel keeps compiled Blade
    views. PHP starts an application for each request; with this store a
    `TemplateSet` restores the templates it renders instead of parsing,
    checking and compiling them every time.

    Each file returns the image of one template (`TemplateImage`) as a PHP
    array literal written by `var_export`: strings, numbers, booleans, null
    and arrays only, never code made from a template. Rendering still runs
    through the renderer, which escapes output and checks URLs as on every
    target. Opcache keeps the arrays in shared memory between requests.

    Keep `root` private and outside the web root. The images of one set
    version live in their own folder, so changed templates or a new image
    format never meet stale files. A file that cannot be read or written
    only means the template is compiled again.
**/
class PhpTemplateStore implements TemplateStore {
    final folder:String;

    /**
        `root` is the cache folder; `version` names the set and the sources
        of its templates, such as an application build or the installed
        folder of a theme.
    **/
    public function new(root:String, version:String) {
        var key = Md5.encode('${TemplateImage.VERSION}\n${version}');
        folder = '${root}/${key}';
    }

    public function load(name:String):Null<Dynamic> {
        // A missing file is a cache miss; the image stays a native array, which
        // TemplateImage reads without copying.
        var data:Dynamic = try Syntax.code("(@include {0})", fileOf(name)) catch (_:Dynamic) null;
        return Global.is_array(data) ? data : null;
    }

    public function save(name:String, image:Array<Dynamic>):Void {
        try {
            if (!Global.is_dir(folder)) {
                // 493 is 0755: readable by the web server, writable by its owner.
                Global.mkdir(folder, 493, true);
            }
            var file = fileOf(name);
            var exported:String = Syntax.code("var_export({0}, true)", toNative(image));
            var source = '<?php\n// A compiled Wellout template image: data only. Generated; do not edit.\nreturn ${exported};\n';
            // Write a private file and rename it, so a concurrent request never reads part of one.
            var temporary = '${file}.${Global.bin2hex(Global.random_bytes(8))}.tmp';
            if (Global.file_put_contents(temporary, source) == false
                || !Global.rename(temporary, file)) {
                Syntax.code("@unlink({0})", temporary);
                return;
            }
            if (Global.function_exists("opcache_invalidate")) {
                Syntax.code("opcache_invalidate({0}, true)", file);
            }
        } catch (_:Dynamic) {}
    }

    /** A file name of letters, digits, `_` and `-` only, whatever the template is called. **/
    function fileOf(name:String):String {
        var readable = ~/[^A-Za-z0-9_-]/g.replace(name, "_");
        var hash = Md5.encode(name).substr(0, 12);
        return '${folder}/${readable}-${hash}.php';
    }

    static function toNative(value:Dynamic):Dynamic {
        if (!Std.isOfType(value, Array)) {
            return value;
        }
        var items:Array<Dynamic> = cast value;
        return Lib.toPhpArray([for (item in items) toNative(item)]);
    }
}
#end
