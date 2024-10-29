module [
    Html,
    text,

    # elements
    html,
    base,
    head,
    link,
    meta,
    style,
    title,
    body,
    address,
    article,
    aside,
    footer,
    header,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    hgroup,
    main,
    nav,
    section,
    search,
    blockquote,
    dd,
    div,
    dl,
    dt,
    figcaption,
    figure,
    hr,
    li,
    menu,
    ol,
    p,
    pre,
    a,
    abbr,
    b,
    bdi,
    bdo,
    br,
    cite,
    code,
    data,
    dfn,
    em,
    i,
    kbd,
    mark,
    q,
    rp,
    rt,
    ruby,
    s,
    samp,
    small,
    span,
    strong,
    sub,
    sup,
    time,
    u,
    var,
    wbr,
    area,
    audio,
    img,
    map,
    track,
    video,
    embed,
    fencedframe,
    iframe,
    object,
    picture,
    portal,
    source,
    svg,
    math,
    canvas,
    noscript,
    script,
    del,
    ins,
    caption,
    col,
    colgroup,
    table,
    tbody,
    td,
    tfoot,
    th,
    thead,
    tr,
    button,
    datalist,
    fieldset,
    form,
    input,
    label,
    legend,
    meter,
    optgroup,
    option,
    output,
    progress,
    select,
    textarea,
    details,
    dialog,
    summary,
    slot,
    template,
]

import XmlInternal

Html : XmlInternal.Xml

text : Str -> Html
text = XmlInternal.text

html = \attributes, children -> XmlInternal.node "html" attributes children

base = \attributes, children -> XmlInternal.node "base" attributes children

head = \attributes, children -> XmlInternal.node "head" attributes children

link = \attributes, children -> XmlInternal.node "link" attributes children

meta = \attributes, children -> XmlInternal.node "meta" attributes children

style = \attributes, children -> XmlInternal.node "style" attributes children

title = \attributes, children -> XmlInternal.node "title" attributes children

body = \attributes, children -> XmlInternal.node "body" attributes children

address = \attributes, children -> XmlInternal.node "address" attributes children

article = \attributes, children -> XmlInternal.node "article" attributes children

aside = \attributes, children -> XmlInternal.node "aside" attributes children

footer = \attributes, children -> XmlInternal.node "footer" attributes children

header = \attributes, children -> XmlInternal.node "header" attributes children

h1 = \attributes, children -> XmlInternal.node "h1" attributes children

h2 = \attributes, children -> XmlInternal.node "h2" attributes children

h3 = \attributes, children -> XmlInternal.node "h3" attributes children

h4 = \attributes, children -> XmlInternal.node "h4" attributes children

h5 = \attributes, children -> XmlInternal.node "h5" attributes children

h6 = \attributes, children -> XmlInternal.node "h6" attributes children

hgroup = \attributes, children -> XmlInternal.node "hgroup" attributes children

main = \attributes, children -> XmlInternal.node "main" attributes children

nav = \attributes, children -> XmlInternal.node "nav" attributes children

section = \attributes, children -> XmlInternal.node "section" attributes children

search = \attributes, children -> XmlInternal.node "search" attributes children

blockquote = \attributes, children -> XmlInternal.node "blockquote" attributes children

dd = \attributes, children -> XmlInternal.node "dd" attributes children

div = \attributes, children -> XmlInternal.node "div" attributes children

dl = \attributes, children -> XmlInternal.node "dl" attributes children

dt = \attributes, children -> XmlInternal.node "dt" attributes children

figcaption = \attributes, children -> XmlInternal.node "figcaption" attributes children

figure = \attributes, children -> XmlInternal.node "figure" attributes children

hr = \attributes, children -> XmlInternal.node "hr" attributes children

li = \attributes, children -> XmlInternal.node "li" attributes children

menu = \attributes, children -> XmlInternal.node "menu" attributes children

ol = \attributes, children -> XmlInternal.node "ol" attributes children

p = \attributes, children -> XmlInternal.node "p" attributes children

pre = \attributes, children -> XmlInternal.node "pre" attributes children

a = \attributes, children -> XmlInternal.node "a" attributes children

abbr = \attributes, children -> XmlInternal.node "abbr" attributes children

b = \attributes, children -> XmlInternal.node "b" attributes children

bdi = \attributes, children -> XmlInternal.node "bdi" attributes children

bdo = \attributes, children -> XmlInternal.node "bdo" attributes children

br = \attributes, children -> XmlInternal.node "br" attributes children

cite = \attributes, children -> XmlInternal.node "cite" attributes children

code = \attributes, children -> XmlInternal.node "code" attributes children

data = \attributes, children -> XmlInternal.node "data" attributes children

dfn = \attributes, children -> XmlInternal.node "dfn" attributes children

em = \attributes, children -> XmlInternal.node "em" attributes children

i = \attributes, children -> XmlInternal.node "i" attributes children

kbd = \attributes, children -> XmlInternal.node "kbd" attributes children

mark = \attributes, children -> XmlInternal.node "mark" attributes children

q = \attributes, children -> XmlInternal.node "q" attributes children

rp = \attributes, children -> XmlInternal.node "rp" attributes children

rt = \attributes, children -> XmlInternal.node "rt" attributes children

ruby = \attributes, children -> XmlInternal.node "ruby" attributes children

s = \attributes, children -> XmlInternal.node "s" attributes children

samp = \attributes, children -> XmlInternal.node "samp" attributes children

small = \attributes, children -> XmlInternal.node "small" attributes children

span = \attributes, children -> XmlInternal.node "span" attributes children

strong = \attributes, children -> XmlInternal.node "strong" attributes children

sub = \attributes, children -> XmlInternal.node "sub" attributes children

sup = \attributes, children -> XmlInternal.node "sup" attributes children

time = \attributes, children -> XmlInternal.node "time" attributes children

u = \attributes, children -> XmlInternal.node "u" attributes children

var = \attributes, children -> XmlInternal.node "var" attributes children

wbr = \attributes, children -> XmlInternal.node "wbr" attributes children

area = \attributes, children -> XmlInternal.node "area" attributes children

audio = \attributes, children -> XmlInternal.node "audio" attributes children

img = \attributes, children -> XmlInternal.node "img" attributes children

map = \attributes, children -> XmlInternal.node "map" attributes children

track = \attributes, children -> XmlInternal.node "track" attributes children

video = \attributes, children -> XmlInternal.node "video" attributes children

embed = \attributes, children -> XmlInternal.node "embed" attributes children

fencedframe = \attributes, children -> XmlInternal.node "fencedframe" attributes children

iframe = \attributes, children -> XmlInternal.node "iframe" attributes children

object = \attributes, children -> XmlInternal.node "object" attributes children

picture = \attributes, children -> XmlInternal.node "picture" attributes children

portal = \attributes, children -> XmlInternal.node "portal" attributes children

source = \attributes, children -> XmlInternal.node "source" attributes children

svg = \attributes, children -> XmlInternal.node "svg" attributes children

math = \attributes, children -> XmlInternal.node "math" attributes children

canvas = \attributes, children -> XmlInternal.node "canvas" attributes children

noscript = \attributes, children -> XmlInternal.node "noscript" attributes children

script = \attributes, children -> XmlInternal.node "script" attributes children

del = \attributes, children -> XmlInternal.node "del" attributes children

ins = \attributes, children -> XmlInternal.node "ins" attributes children

caption = \attributes, children -> XmlInternal.node "caption" attributes children

col = \attributes, children -> XmlInternal.node "col" attributes children

colgroup = \attributes, children -> XmlInternal.node "colgroup" attributes children

table = \attributes, children -> XmlInternal.node "table" attributes children

tbody = \attributes, children -> XmlInternal.node "tbody" attributes children

td = \attributes, children -> XmlInternal.node "td" attributes children

tfoot = \attributes, children -> XmlInternal.node "tfoot" attributes children

th = \attributes, children -> XmlInternal.node "th" attributes children

thead = \attributes, children -> XmlInternal.node "thead" attributes children

tr = \attributes, children -> XmlInternal.node "tr" attributes children

button = \attributes, children -> XmlInternal.node "button" attributes children

datalist = \attributes, children -> XmlInternal.node "datalist" attributes children

fieldset = \attributes, children -> XmlInternal.node "fieldset" attributes children

form = \attributes, children -> XmlInternal.node "form" attributes children

input = \attributes, children -> XmlInternal.node "input" attributes children

label = \attributes, children -> XmlInternal.node "label" attributes children

legend = \attributes, children -> XmlInternal.node "legend" attributes children

meter = \attributes, children -> XmlInternal.node "meter" attributes children

optgroup = \attributes, children -> XmlInternal.node "optgroup" attributes children

option = \attributes, children -> XmlInternal.node "option" attributes children

output = \attributes, children -> XmlInternal.node "output" attributes children

progress = \attributes, children -> XmlInternal.node "progress" attributes children

select = \attributes, children -> XmlInternal.node "select" attributes children

textarea = \attributes, children -> XmlInternal.node "textarea" attributes children

details = \attributes, children -> XmlInternal.node "details" attributes children

dialog = \attributes, children -> XmlInternal.node "dialog" attributes children

summary = \attributes, children -> XmlInternal.node "summary" attributes children

slot = \attributes, children -> XmlInternal.node "slot" attributes children

template = \attributes, children -> XmlInternal.node "template" attributes children

