// A script for generating platform/Html.roc from a list of HTML tags and
// attributes.
//
// To run:
//
//     zig run build/gen_html_roc.zig > platform/Html.roc
//

const std = @import("std");

const Tag = struct {
    name: []const u8,
    attrs: []const []const u8,
};

// https://developer.mozilla.org/en-US/docs/Web/HTML/Element
const tags = [_]Tag{
    Tag{ .name = "html", .attrs = &.{} },
    Tag{ .name = "base", .attrs = &.{ "href", "target" } },
    Tag{ .name = "head", .attrs = &.{} },
    Tag{ .name = "link", .attrs = &.{ "as", "crossorigin", "disabled", "fetchpriority", "href", "hreflang", "imagesizes", "imagesrcset", "integrity", "media", "referrerpolicy", "rel", "sizes", "type" } },
    Tag{ .name = "meta", .attrs = &.{ "charset", "content", "http-equiv", "name" } },
    Tag{ .name = "style", .attrs = &.{"media"} },
    Tag{ .name = "title", .attrs = &.{} },
    Tag{ .name = "body", .attrs = &.{ "onafterprint", "onbeforeprint", "onbeforeunload", "onhashchange", "onlanguagechange", "onmessage", "onoffline", "ononline", "onpopstate", "onstorage", "onunload" } },
    Tag{ .name = "address", .attrs = &.{} },
    Tag{ .name = "article", .attrs = &.{} },
    Tag{ .name = "aside", .attrs = &.{} },
    Tag{ .name = "footer", .attrs = &.{} },
    Tag{ .name = "header", .attrs = &.{} },
    Tag{ .name = "h1", .attrs = &.{} },
    Tag{ .name = "h2", .attrs = &.{} },
    Tag{ .name = "h3", .attrs = &.{} },
    Tag{ .name = "h4", .attrs = &.{} },
    Tag{ .name = "h5", .attrs = &.{} },
    Tag{ .name = "h6", .attrs = &.{} },
    Tag{ .name = "hgroup", .attrs = &.{} },
    Tag{ .name = "main", .attrs = &.{} },
    Tag{ .name = "nav", .attrs = &.{} },
    Tag{ .name = "section", .attrs = &.{} },
    Tag{ .name = "search", .attrs = &.{} },
    Tag{ .name = "blockquote", .attrs = &.{"cite"} },
    Tag{ .name = "dd", .attrs = &.{} },
    Tag{ .name = "div", .attrs = &.{} },
    Tag{ .name = "dl", .attrs = &.{} },
    Tag{ .name = "dt", .attrs = &.{} },
    Tag{ .name = "figcaption", .attrs = &.{} },
    Tag{ .name = "figure", .attrs = &.{} },
    Tag{ .name = "hr", .attrs = &.{} },
    Tag{ .name = "li", .attrs = &.{"value"} },
    Tag{ .name = "menu", .attrs = &.{ "reversed", "start", "type" } },
    Tag{ .name = "ol", .attrs = &.{} },
    Tag{ .name = "p", .attrs = &.{} },
    Tag{ .name = "pre", .attrs = &.{} },
    Tag{ .name = "a", .attrs = &.{ "download", "href", "hreflang", "ping", "referrerpolicy", "rel", "target", "type" } },
    Tag{ .name = "abbr", .attrs = &.{} },
    Tag{ .name = "b", .attrs = &.{} },
    Tag{ .name = "bdi", .attrs = &.{} },
    Tag{ .name = "bdo", .attrs = &.{} },
    Tag{ .name = "br", .attrs = &.{} },
    Tag{ .name = "cite", .attrs = &.{} },
    Tag{ .name = "code", .attrs = &.{} },
    Tag{ .name = "data", .attrs = &.{"value"} },
    Tag{ .name = "dfn", .attrs = &.{} },
    Tag{ .name = "em", .attrs = &.{} },
    Tag{ .name = "i", .attrs = &.{} },
    Tag{ .name = "kbd", .attrs = &.{} },
    Tag{ .name = "mark", .attrs = &.{} },
    Tag{ .name = "q", .attrs = &.{"cite"} },
    Tag{ .name = "rp", .attrs = &.{} },
    Tag{ .name = "rt", .attrs = &.{} },
    Tag{ .name = "ruby", .attrs = &.{} },
    Tag{ .name = "s", .attrs = &.{} },
    Tag{ .name = "samp", .attrs = &.{} },
    Tag{ .name = "small", .attrs = &.{} },
    Tag{ .name = "span", .attrs = &.{} },
    Tag{ .name = "strong", .attrs = &.{} },
    Tag{ .name = "sub", .attrs = &.{} },
    Tag{ .name = "sup", .attrs = &.{} },
    Tag{ .name = "time", .attrs = &.{"datetime"} },
    Tag{ .name = "u", .attrs = &.{} },
    Tag{ .name = "var", .attrs = &.{} },
    Tag{ .name = "wbr", .attrs = &.{} },
    Tag{ .name = "area", .attrs = &.{ "alt", "coords", "download", "href", "ping", "referrerpolicy", "rel", "shape", "target" } },
    Tag{ .name = "audio", .attrs = &.{ "autoplay", "controls", "controlslist", "crossorigin", "disableremoteplayback", "loop", "muted", "preload", "src" } },
    Tag{ .name = "img", .attrs = &.{ "alt", "crossorigin", "decoding", "elementtiming", "fetchpriority", "height", "ismap", "loading", "referrerpolicy", "sizes", "src", "srcset", "width", "usemap" } },
    Tag{ .name = "map", .attrs = &.{"name"} },
    Tag{ .name = "track", .attrs = &.{ "default", "kind", "label", "src", "srclang" } },
    Tag{ .name = "video", .attrs = &.{ "autoplay", "controls", "controlslist", "crossorigin", "disablepictureinpicture", "disableremoteplayback", "height", "loop", "muted", "playsinline", "poster", "preload", "src", "width" } },
    Tag{ .name = "embed", .attrs = &.{ "height", "src", "type", "width" } },
    Tag{ .name = "fencedframe", .attrs = &.{} },
    Tag{ .name = "iframe", .attrs = &.{ "allow", "allowfullscreen", "height", "loading", "name", "referrerpolicy", "sandbox", "src", "srcdoc", "width" } },
    Tag{ .name = "object", .attrs = &.{ "data", "form", "height", "name", "type", "width" } },
    Tag{ .name = "picture", .attrs = &.{} },
    Tag{ .name = "portal", .attrs = &.{ "referrerpolicy", "src" } },
    Tag{ .name = "source", .attrs = &.{ "type", "src", "srcset", "sizes", "media", "height", "width" } },
    Tag{ .name = "svg", .attrs = &.{ "height", "preserveAspectRatio", "viewBox", "width", "x", "y" } },
    Tag{ .name = "math", .attrs = &.{"display"} },
    Tag{ .name = "canvas", .attrs = &.{ "height", "width" } },
    Tag{ .name = "noscript", .attrs = &.{} },
    Tag{ .name = "script", .attrs = &.{ "async", "crossorigin", "defer", "fetchpriority", "integrity", "nomodule", "referrerpolicy", "src", "type" } },
    Tag{ .name = "del", .attrs = &.{ "cite", "datetime" } },
    Tag{ .name = "ins", .attrs = &.{ "cite", "datetime" } },
    Tag{ .name = "caption", .attrs = &.{} },
    Tag{ .name = "col", .attrs = &.{"span"} },
    Tag{ .name = "colgroup", .attrs = &.{"span"} },
    Tag{ .name = "table", .attrs = &.{} },
    Tag{ .name = "tbody", .attrs = &.{} },
    Tag{ .name = "td", .attrs = &.{ "colspan", "headers", "rowspan" } },
    Tag{ .name = "tfoot", .attrs = &.{} },
    Tag{ .name = "th", .attrs = &.{ "abbr", "colspan", "headers", "rowspan", "scope" } },
    Tag{ .name = "thead", .attrs = &.{} },
    Tag{ .name = "tr", .attrs = &.{} },
    Tag{ .name = "button", .attrs = &.{ "command", "commandfor", "disabled", "form", "formaction", "formenctype", "formmethod", "formnovalidate", "formtarget", "name", "popovertarget", "popovertargetaction", "type", "value" } },
    Tag{ .name = "datalist", .attrs = &.{} },
    Tag{ .name = "fieldset", .attrs = &.{ "disabled", "form", "name" } },
    Tag{ .name = "form", .attrs = &.{ "accept-charset", "autocomplete", "name", "rel", "action", "enctype", "method", "novalidate", "target" } },
    Tag{ .name = "input", .attrs = &.{ "accept", "alt", "autocomplete", "capture", "checked", "dirname", "disabled", "form", "formaction", "formenctype", "formmethod", "formnovalidate", "formtarget", "height", "list", "max", "maxlength", "min", "minlength", "multiple", "name", "pattern", "placeholder", "popovertarget", "popovertargetaction", "readonly", "required", "size", "src", "step", "type", "value", "width" } },
    Tag{ .name = "label", .attrs = &.{"for"} },
    Tag{ .name = "legend", .attrs = &.{} },
    Tag{ .name = "meter", .attrs = &.{ "form", "value", "min", "max", "low", "high", "optimum" } },
    Tag{ .name = "optgroup", .attrs = &.{ "disabled", "label" } },
    Tag{ .name = "option", .attrs = &.{ "disabled", "label", "selected", "value" } },
    Tag{ .name = "output", .attrs = &.{ "for", "form", "name" } },
    Tag{ .name = "progress", .attrs = &.{ "max", "value" } },
    Tag{ .name = "select", .attrs = &.{ "autocomplete", "disabled", "form", "multiple", "name", "required", "size" } },
    Tag{ .name = "textarea", .attrs = &.{ "autocomplete", "cols", "dirname", "disabled", "form", "maxlength", "minlength", "name", "placeholder", "readonly", "required", "rows", "wrap" } },
    Tag{ .name = "details", .attrs = &.{ "open", "name" } },
    Tag{ .name = "dialog", .attrs = &.{"open"} },
    Tag{ .name = "summary", .attrs = &.{} },
    Tag{ .name = "slot", .attrs = &.{"name"} },
    Tag{ .name = "template", .attrs = &.{ "shadowrootmode", "shadowrootclonable", "shadowrootdelegatesfocus" } },
};

// https://developer.mozilla.org/en-US/docs/Web/HTML/Global_attributes
const global_attributes = [_][]const u8{
    // XML inherited
    "xmlLang",
    "xmlBase",

    // Global attributes
    "accesskey",
    "autocapitalize",
    "autofocus",
    "class",
    "contenteditable",
    "dir",
    "draggable",
    "onenterkeyhint",
    "exportparts",
    "hidden",
    "id",
    "inert",
    "inputmode",
    "is",
    "itemid",
    "itemprop",
    "itemref",
    "itemscope",
    "itemtype",
    "lang",
    "nonce",
    "part",
    "popover",
    "role",
    "slot",
    "spellcheck",
    "style",
    "tabindex",
    "title",
    "translate",
    "writingsuggestions",

    // Event handlers
    "onabort",
    "onautocomplete",
    "onautocompleteerror",
    "onblur",
    "oncancel",
    "oncanplay",
    "oncanplaythrough",
    "onchange",
    "onclick",
    "onclose",
    "oncontextmenu",
    "oncuechange",
    "ondblclick",
    "ondrag",
    "ondragend",
    "ondragenter",
    "ondragleave",
    "ondragover",
    "ondragstart",
    "ondrop",
    "ondurationchange",
    "onemptied",
    "onended",
    "onerror",
    "onfocus",
    "oninput",
    "oninvalid",
    "onkeydown",
    "onkeypress",
    "onkeyup",
    "onload",
    "onloadeddata",
    "onloadedmetadata",
    "onloadstart",
    "onmousedown",
    "onmouseenter",
    "onmouseleave",
    "onmousemove",
    "onmouseout",
    "onmouseover",
    "onmouseup",
    "onmousewheel",
    "onpause",
    "onplay",
    "onplaying",
    "onprogress",
    "onratechange",
    "onreset",
    "onresize",
    "onscroll",
    "onseeked",
    "onseeking",
    "onselect",
    "onshow",
    "onsort",
    "onstalled",
    "onsubmit",
    "onsuspend",
    "ontimeupdate",
    "ontoggle",
    "onvolumechange",
    "onwaiting",

    // ARIA
    "ariaAutocomplete",
    "ariaChecked",
    "ariaDisabled",
    "ariaErrorMessage",
    "ariaExpanded",
    "ariaHaspopup",
    "ariaHidden",
    "ariaInvalid",
    "ariaLabel",
    "ariaLevel",
    "ariaModal",
    "ariaMultiline",
    "ariaMultiselectable",
    "ariaOrientation",
    "ariaPlaceholder",
    "ariaPressed",
    "ariaReadonly",
    "ariaRequired",
    "ariaSelected",
    "ariaSort",
    "ariaValuemax",
    "ariaValuemin",
    "ariaValuenow",
    "ariaValuetext",
    "ariaBusy",
    "ariaLive",
    "ariaRelevant",
    "ariaAtomic",
    "ariaDropeffect",
    "ariaGrabbed",
    "ariaActivedescendant",
    "ariaColcount",
    "ariaColindex",
    "ariaColspan",
    "ariaControls",
    "ariaDescribedby",
    "ariaDescription",
    "ariaDetails",
    "ariaFlowto",
    "ariaLabelledby",
    "ariaOwns",
    "ariaPosinset",
    "ariaRowcount",
    "ariaRowindex",
    "ariaRowspan",
    "ariaSetsize",
    "ariaKeyshortcuts",
    "ariaRoledescription",
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    print(stdout) catch |err| {
        const stderr = std.io.getStdOut().writer();
        stderr.print("Error: {any}", .{err}) catch {};
        std.process.exit(1);
    };
}

pub fn print(writer: std.fs.File.Writer) !void {
    try writer.writeAll(
        \\# THIS FILE IS GENERATED BY ./build/gen_html_roc.zig
        \\
        \\module [
        \\    Html,
        \\    text,
        \\
        \\    # elements
        \\
    );
    for (tags) |tag| {
        try writer.print("    {s},\n", .{tag.name});
    }
    try writer.writeAll(
        \\]
        \\
        \\import Xml.Internal
        \\
        \\Html : Xml.Internal.Xml
        \\
        \\text : Str -> Html
        \\text = Xml.Internal.text
        \\
        \\
    );
    for (tags) |tag| {
        try writer.print("{s} : {{ ", .{tag.name});
        try printAttrs("{s} ? Str", ", {s} ? Str", writer, tag.attrs);
        try writer.print(
            \\}}, List Html -> Html
            \\{s} = \{{
        , .{tag.name});
        try printAttrs("{s} ? \"\"", ", {s} ? \"\"", writer, tag.attrs);
        try writer.print(" }}, children -> Xml.Internal.node \"{s}\" {{ ", .{tag.name});
        try printAttrs("{s}", ", {s}", writer, tag.attrs);
        try writer.writeAll(" } children\n\n");
    }
}

fn printAttrs(
    comptime first: []const u8,
    comptime rest: []const u8,
    writer: std.fs.File.Writer,
    attrs: []const []const u8,
) !void {
    try writer.print(first, .{global_attributes[0]});
    for (global_attributes[1..]) |attr| {
        if (!skipAttr(attr)) continue;
        try writer.print(rest, .{attr});
    }
    for (attrs) |attr| {
        if (!skipAttr(attr)) continue;
        try writer.print(rest, .{attr});
    }
}

// TODO: figure out a way not to skip any attributes
fn skipAttr(attr: []const u8) bool {
    if (std.mem.eql(u8, attr, "abbr")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "accept-charset")) return false; // name contains invalid byte.
    if (std.mem.eql(u8, attr, "as")) return false; // reserved keyword.
    if (std.mem.eql(u8, attr, "cite")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "data")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "form")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "http-equiv")) return false; // name contains invalid byte.
    if (std.mem.eql(u8, attr, "is")) return false; // reserved keyword.
    if (std.mem.eql(u8, attr, "label")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "slot")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "span")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "style")) return false; // conflicts with element of same name.
    if (std.mem.eql(u8, attr, "title")) return false; // conflicts with element of same name.
    return true;
}
