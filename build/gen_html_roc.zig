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
    Tag{ .name = "base", .attrs = &.{} },
    Tag{ .name = "head", .attrs = &.{} },
    Tag{ .name = "link", .attrs = &.{} },
    Tag{ .name = "meta", .attrs = &.{} },
    Tag{ .name = "style", .attrs = &.{} },
    Tag{ .name = "title", .attrs = &.{} },
    Tag{ .name = "body", .attrs = &.{} },
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
    Tag{ .name = "blockquote", .attrs = &.{} },
    Tag{ .name = "dd", .attrs = &.{} },
    Tag{ .name = "div", .attrs = &.{} },
    Tag{ .name = "dl", .attrs = &.{} },
    Tag{ .name = "dt", .attrs = &.{} },
    Tag{ .name = "figcaption", .attrs = &.{} },
    Tag{ .name = "figure", .attrs = &.{} },
    Tag{ .name = "hr", .attrs = &.{} },
    Tag{ .name = "li", .attrs = &.{} },
    Tag{ .name = "menu", .attrs = &.{} },
    Tag{ .name = "ol", .attrs = &.{} },
    Tag{ .name = "p", .attrs = &.{} },
    Tag{ .name = "pre", .attrs = &.{} },
    Tag{ .name = "a", .attrs = &.{} },
    Tag{ .name = "abbr", .attrs = &.{} },
    Tag{ .name = "b", .attrs = &.{} },
    Tag{ .name = "bdi", .attrs = &.{} },
    Tag{ .name = "bdo", .attrs = &.{} },
    Tag{ .name = "br", .attrs = &.{} },
    Tag{ .name = "cite", .attrs = &.{} },
    Tag{ .name = "code", .attrs = &.{} },
    Tag{ .name = "data", .attrs = &.{} },
    Tag{ .name = "dfn", .attrs = &.{} },
    Tag{ .name = "em", .attrs = &.{} },
    Tag{ .name = "i", .attrs = &.{} },
    Tag{ .name = "kbd", .attrs = &.{} },
    Tag{ .name = "mark", .attrs = &.{} },
    Tag{ .name = "q", .attrs = &.{} },
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
    Tag{ .name = "time", .attrs = &.{} },
    Tag{ .name = "u", .attrs = &.{} },
    Tag{ .name = "var", .attrs = &.{} },
    Tag{ .name = "wbr", .attrs = &.{} },
    Tag{ .name = "area", .attrs = &.{} },
    Tag{ .name = "audio", .attrs = &.{} },
    Tag{ .name = "img", .attrs = &.{} },
    Tag{ .name = "map", .attrs = &.{} },
    Tag{ .name = "track", .attrs = &.{} },
    Tag{ .name = "video", .attrs = &.{} },
    Tag{ .name = "embed", .attrs = &.{} },
    Tag{ .name = "fencedframe", .attrs = &.{} },
    Tag{ .name = "iframe", .attrs = &.{} },
    Tag{ .name = "object", .attrs = &.{} },
    Tag{ .name = "picture", .attrs = &.{} },
    Tag{ .name = "portal", .attrs = &.{} },
    Tag{ .name = "source", .attrs = &.{} },
    Tag{ .name = "svg", .attrs = &.{} },
    Tag{ .name = "math", .attrs = &.{} },
    Tag{ .name = "canvas", .attrs = &.{} },
    Tag{ .name = "noscript", .attrs = &.{} },
    Tag{ .name = "script", .attrs = &.{} },
    Tag{ .name = "del", .attrs = &.{} },
    Tag{ .name = "ins", .attrs = &.{} },
    Tag{ .name = "caption", .attrs = &.{} },
    Tag{ .name = "col", .attrs = &.{} },
    Tag{ .name = "colgroup", .attrs = &.{} },
    Tag{ .name = "table", .attrs = &.{} },
    Tag{ .name = "tbody", .attrs = &.{} },
    Tag{ .name = "td", .attrs = &.{} },
    Tag{ .name = "tfoot", .attrs = &.{} },
    Tag{ .name = "th", .attrs = &.{} },
    Tag{ .name = "thead", .attrs = &.{} },
    Tag{ .name = "tr", .attrs = &.{} },
    Tag{ .name = "button", .attrs = &.{} },
    Tag{ .name = "datalist", .attrs = &.{} },
    Tag{ .name = "fieldset", .attrs = &.{} },
    Tag{ .name = "form", .attrs = &.{} },
    Tag{ .name = "input", .attrs = &.{} },
    Tag{ .name = "label", .attrs = &.{} },
    Tag{ .name = "legend", .attrs = &.{} },
    Tag{ .name = "meter", .attrs = &.{} },
    Tag{ .name = "optgroup", .attrs = &.{} },
    Tag{ .name = "option", .attrs = &.{} },
    Tag{ .name = "output", .attrs = &.{} },
    Tag{ .name = "progress", .attrs = &.{} },
    Tag{ .name = "select", .attrs = &.{} },
    Tag{ .name = "textarea", .attrs = &.{} },
    Tag{ .name = "details", .attrs = &.{} },
    Tag{ .name = "dialog", .attrs = &.{} },
    Tag{ .name = "summary", .attrs = &.{} },
    Tag{ .name = "slot", .attrs = &.{} },
    Tag{ .name = "template", .attrs = &.{} },
};

// https://developer.mozilla.org/en-US/docs/Web/HTML/Global_attributes
// TODO: data-* attributes?
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
    "itempro",
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
    "ariaRoleDescription",
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
        \\import XmlInternal
        \\
        \\Html : XmlInternal.Xml
        \\
        \\text : Str -> Html
        \\text = XmlInternal.text
        \\
        \\
    );
    for (tags) |tag| {
        try writer.print(
            \\{s} = \attributes, children -> XmlInternal.node "{s}" attributes children
            \\
            \\
        , .{ tag.name, tag.name });
    }
}
