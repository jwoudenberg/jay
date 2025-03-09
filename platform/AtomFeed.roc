module [create, feed, entry, link, person, category, Feed, Entry, Link, Person, Category]

import Html exposing [Html]
import Xml.Internal exposing [Xml, unwrap, node, text, each, empty, xml_to_str_for_tests]

# Atom feed documentation: https://validator.w3.org/feed/docs/atom.html#content
# TODO: produce warnings if the Atom feed is invalid
# TODO: add documentation comments
create : Feed, List Entry -> Xml
create = |{ id, title, updated, links, authors, categories, contributors, icon, logo, rights, subtitle }, entries|
    node "feed" { xmlns: "http://www.w3.org/2005/Atom" } [
        node "id" {} [text id],
        node "title" { type: "xhtml" } [embedHtml title],
        each links renderLink,
        node "updated" {} [text updated],
        each authors |author| renderPerson "author" author,
        each categories renderCategory,
        each contributors |contributor| renderPerson "contributor" contributor,
        node "generator" { uri: "https://jay.jasperwoudenberg.com" } [],
        if (icon == "") then empty else node "icon" {} [text icon],
        if (logo == "") then empty else node "logo" {} [text logo],
        if (unwrap rights == []) then empty else node "rights" { type: "xhtml" } [embedHtml rights],
        if (subtitle == "") then empty else node "subtitle" {} [text subtitle],
        each entries renderEntry,
    ]
    |> Xml.Internal.set_prefix (Str.to_utf8 "<?xml version=\"1.0\" encoding=\"utf-8\"?>")

# Minimal example
expect
    actual_feed : Feed
    actual_feed = {
        id: "jay.jasperwoudenberg.com/news",
        title: text "Feed",
        updated: "2025-03-09T19:58:22Z",
        authors: [
            { name: "Jasper", email: "jasper@example.com", uri: "jasper.example.com" },
            person { name: "Daniel" },
        ],
        links: [
            { href: "one.example.com", rel: "alternate", type: "html", hreflang: "en", title: "link", length: 100 },
            link { href: "two.example.com" },
        ],
        categories: [
            { term: "cats", scheme: "cats.example.com", label: "Cats!" },
            category { term: "dogs" },
        ],
        contributors: [
            { name: "Bastiaan", email: "bastiaan@example.com", uri: "bastiaan.example.com" },
            person { name: "Mattias" },
        ],
        icon: "icon.jpg",
        logo: "logo.png",
        rights: text "All rights reversed",
        subtitle: "your tagline here",
    }

    entry1 : Entry
    entry1 = {
        id: "1",
        title: text "first post",
        updated: "2021-08-12T12:47:23Z",
        content: text "interesting texts",
        summary: text "alluring pitch",
        authors: [
            # TODO: temporarily uncommented to work around segfaults in test runs.
            # { name: "Jaap", email: "jaap@example.com", uri: "jaap.example.com" },
            # person { name: "Margrit" },
        ],
        links: [
            # TODO: temporarily uncommented to work around segfaults in test runs.
            # { href: "one.example.com", rel: "alternate", type: "html", hreflang: "en", title: "link", length: 100 },
            # link { href: "two.example.com" },
        ],
        categories: [
            # TODO: temporarily uncommented to work around segfaults in test runs.
            # { term: "cats", scheme: "cats.example.com", label: "Cats!" },
            # category { term: "dogs" },
        ],
        contributors: [
            # TODO: temporarily uncommented to work around segfaults in test runs.
            # { name: "Marianna", email: "marianna@example.com", uri: "marianna.example.com" },
            # person { name: "Marco" },
        ],
        published: "2021-05-22T09:11:11Z",
        rights: text "the best rights",
    }

    entry2 : Entry
    entry2 = entry { id: "2", title: text "second post", updated: "2025-03-09T05:01:56Z" }

    actual =
        create actual_feed [entry1, entry2]
        |> xml_to_str_for_tests
        |> Str.replace_each ">" ">\n"

    expected =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <id>
        jay.jasperwoudenberg.com/news</id>
        <title type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        Feed</div>
        </title>
        <link href="two.example.com">
        </link>
        <link href="one.example.com" hreflang="en" length="100" rel="alternate" title="link" type="html">
        </link>
        <updated>
        2025-03-09T19:58:22Z</updated>
        <author>
        <name>
        Daniel</name>
        </author>
        <author>
        <name>
        Jasper</name>
        <email>
        jasper@example.com</email>
        <uri>
        jasper.example.com</uri>
        </author>
        <category term="dogs">
        </category>
        <category label="Cats!" scheme="cats.example.com" term="cats">
        </category>
        <contributor>
        <name>
        Mattias</name>
        </contributor>
        <contributor>
        <name>
        Bastiaan</name>
        <email>
        bastiaan@example.com</email>
        <uri>
        bastiaan.example.com</uri>
        </contributor>
        <generator uri="https://jay.jasperwoudenberg.com">
        </generator>
        <icon>
        icon.jpg</icon>
        <logo>
        logo.png</logo>
        <rights type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        All rights reversed</div>
        </rights>
        <subtitle>
        your tagline here</subtitle>
        <entry>
        <id>
        2</id>
        <title type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        second post</div>
        </title>
        <updated>
        2025-03-09T05:01:56Z</updated>
        </entry>
        <entry>
        <id>
        1</id>
        <title type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        first post</div>
        </title>
        <updated>
        2021-08-12T12:47:23Z</updated>
        <content type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        interesting texts</div>
        </content>
        <summary type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        alluring pitch</div>
        </summary>
        <rights type="xhtml">
        <div xmlns="http://www.w3.org/1999/xhtml">
        the best rights</div>
        </rights>
        <published>
        2021-05-22T09:11:11Z</published>
        </entry>
        </feed>

        """

    expected == actual

# All optional parameters set
expect
    actual_feed =
        feed {
            id: "jay.jasperwoudenberg.com/news",
            title: text "Feed",
            updated: "2025-03-09T19:58:22Z",
        }

    actual =
        create actual_feed []
        |> xml_to_str_for_tests
        |> Str.replace_each ">" ">\n"

    expected =
        """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <feed xmlns=\"http://www.w3.org/2005/Atom\">
        <id>
        jay.jasperwoudenberg.com/news</id>
        <title type=\"xhtml\">
        <div xmlns=\"http://www.w3.org/1999/xhtml\">
        Feed</div>
        </title>
        <updated>
        2025-03-09T19:58:22Z</updated>
        <generator uri=\"https://jay.jasperwoudenberg.com\">
        </generator>
        </feed>

        """

    expected == actual

renderEntry : Entry -> Xml
renderEntry = |{ id, title, updated, content, summary, links, authors, categories, contributors, rights, published }|
    node "entry" {} [
        node "id" {} [text id],
        node "title" { type: "xhtml" } [embedHtml title],
        node "updated" {} [text updated],
        if (unwrap content == []) then empty else node "content" { type: "xhtml" } [embedHtml content],
        if (unwrap summary == []) then empty else node "summary" { type: "xhtml" } [embedHtml summary],
        each links renderLink,
        each authors |author| renderPerson "author" author,
        each categories renderCategory,
        each contributors |contributor| renderPerson "contributor" contributor,
        if (unwrap rights == []) then empty else node "rights" { type: "xhtml" } [embedHtml rights],
        if (published == "") then empty else node "published" {} [text published],
    ]

embedHtml : Html -> Xml
embedHtml = |html|
    node "div" { xmlns: "http://www.w3.org/1999/xhtml" } [html]

renderLink : Link -> Xml
renderLink = |{ href, rel, type, hreflang, title, length }|
    node
        "link"
        {
            href,
            rel,
            type,
            hreflang,
            title,
            length: if length == Num.max_u64 then "" else Num.to_str length,
        }
        []

renderPerson : Str, Person -> Xml
renderPerson = |tag_name, { name, email, uri }|
    node tag_name {} [
        node "name" {} [text name],
        if (email == "") then empty else node "email" {} [text email],
        if (uri == "") then empty else node "uri" {} [text uri],
    ]

renderCategory : Category -> Xml
renderCategory = |{ term, scheme, label }|
    node "category" { term, scheme, label } []

Feed : {
    id : Str,
    title : Html,
    updated : Str,
    authors : List Person,
    links : List Link,
    categories : List Category,
    contributors : List Person,
    icon : Str,
    logo : Str,
    rights : Html,
    subtitle : Str,
}

feed : { id : Str, title : Html, updated : Str } -> Feed
feed = |{ id, title, updated }| {
    id,
    title,
    updated,
    authors: [],
    links: [],
    categories: [],
    contributors: [],
    icon: "",
    logo: "",
    rights: empty,
    subtitle: "",
}

Entry : {
    id : Str,
    title : Html,
    updated : Str,
    content : Html,
    summary : Html,
    links : List Link,
    authors : List Person,
    categories : List Category,
    contributors : List Person,
    published : Str,
    rights : Html,
}

entry : { id : Str, title : Html, updated : Str } -> Entry
entry = |{ id, title, updated }| {
    id,
    title,
    updated,
    content: empty,
    summary: empty,
    links: [],
    authors: [],
    categories: [],
    contributors: [],
    published: "",
    rights: empty,
}

Link : {
    href : Str,
    rel : Str,
    type : Str,
    hreflang : Str,
    title : Str,
    length : U64,
}

link : { href : Str } -> Link
link = |{ href }| {
    href,
    rel: "",
    type: "",
    hreflang: "",
    title: "",
    length: Num.max_u64,
}

Person : {
    name : Str,
    email : Str,
    uri : Str,
}

person : { name : Str } -> Person
person = |{ name }| {
    name,
    email: "",
    uri: "",
}

Category : {
    term : Str,
    scheme : Str,
    label : Str,
}

category : { term : Str } -> Category
category = |{ term }| {
    term,
    scheme: "",
    label: "",
}

