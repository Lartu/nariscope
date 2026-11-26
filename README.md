# Gopher Browser

A native macOS Gopher browser written in Swift. The toolbar accepts a hostname
or a `gopher://` URL, and the home button opens Floodgap. Menus, text documents,
type-7 search, common image formats, and file downloads are supported. HTTP
and HTTPS links open in the default web browser.

The HTML reading view uses the same decisions as the Python corpus renderer.
It turns hard-wrapped prose into paragraphs and keeps drawings, columns, and
code in preformatted blocks. **Original layout** shows the source
spacing for text and menu descriptions. Menu links remain clickable in either
view. The application generates its own HTML and displays remote text as text.

## Custom CSS

Open **Gopher Browser → Settings** (⌘,) to edit the current stylesheet. On
first launch it starts with the complete built-in theme from
[Reader.css](Sources/GopherBrowser/Resources/Reader.css). Edit it in place or
load a UTF-8 stylesheet to replace it. Click **Apply** to update every open
reading pane. The setting persists between launches and applies to menus and
Original Layout. Choose **Restore Defaults** and **Apply** to restore the
built-in theme. Existing overrides from version 1.1 appear after the defaults
when you first open the editor.

External CSS imports and remote fonts are blocked.

## Build

Requires macOS 13 or later and a Swift 5.9 or newer toolchain. There are no
third-party dependencies.

```sh
swift test
swift run GopherBrowser
bash build-app.sh
```

`build-app.sh` produces a locally signed `Gopher Browser.app` for the build
machine's architecture. Pass an output directory and a Swift build directory
as positional arguments to keep artifacts outside the source tree.

To start at a particular address, pass a Gopher URL to the executable.

```sh
swift run GopherBrowser gopher://gopher.floodgap.com/1
```

The core tests cover URL and selector bytes, menu parsing, rendering, and
escaping. Set `GOPHER_TEST_URL` to a Gopher server whose root includes a text
link to run the network integration test. Set `GOPHER_PARITY_FIXTURE` to a JSON
file of objects with `name`, `source`, and `expected` fields to check a corpus
against reference HTML.

The client connects directly over plaintext Gopher TCP and limits responses
to 16 MiB with a 20-second request timeout.
