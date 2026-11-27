# Nariscope

A native macOS Gopher browser written in Swift. The toolbar accepts a hostname
or a `gopher://` URL, and the home button opens your homepage. Menus, text documents,
type-7 search, common image formats, and file downloads are supported. HTTP
and HTTPS links open in the default web browser.

Use **⌘T** or the **+** toolbar button for a new tab. The tab bar appears when
there is more than one tab. Middle-click a Gopher link or choose
**Open in New Tab** from its context menu to open it in a background tab.
Command-click a Gopher link to open a new window. Middle-click a tab to close
it. **⌘W** closes the selected tab, or the window when it has one tab.
Each tab keeps its own history and scroll position.
New browser windows use the most recently used browser window's size, even
after restarting Nariscope.
Click the star beside the address field to save or remove a
bookmark. The macOS **Bookmarks** menu opens saved addresses in the current
tab, and **⌘D** adds the current page. Bookmarks are shared across windows and
persist across launches.

The **History** menu lists recent visits and opens a searchable history with
**⌘Y**. Use **⇧⌘W** to reopen the last closed tab. The menu can also reopen
the last closed window or open the windows from the previous session in
addition to the current windows. Restored tabs keep their navigation history
and reload their pages.

The HTML reading view uses the same decisions as the Python corpus renderer.
It turns hard-wrapped prose into paragraphs and keeps drawings, columns, and
code in preformatted blocks. The **Original layout** icon beside the bookmark
star shows the source spacing for text and menu descriptions. Menu links remain
clickable in either view. The application generates its own HTML and displays
remote text as text.

## Settings

In **Nariscope → Settings → General**, enter a homepage address, set it to the
current page, or choose a blank page. The homepage is used at launch, in new
windows, and by the Home button. The default is Floodgap.

Nariscope follows the macOS appearance and switches open pages between its
[light stylesheet](Sources/Nariscope/Resources/Reader.css) and
[dark stylesheet](Sources/Nariscope/Resources/ReaderDark.css).
Open **Nariscope → Settings** (⌘,), choose **Stylesheet**, and select **Light**
or **Dark** to edit that mode. Edit the CSS in place or load a UTF-8 stylesheet,
then click **Apply**. Each mode is saved separately and styles both menus and
Original Layout. **Restore Defaults** followed by **Apply** resets the selected
mode. Previously saved custom CSS carries over to the Light stylesheet.
Use `.loadingtext` to style the heading shown while a page loads.

External CSS imports and remote fonts are blocked.

In the packaged app, the **App Icon** pane offers **Sunny**, **Violet**,
**Blue**, and **Space**. The choice takes effect in the Dock and is restored on launch.
Finder uses Sunny as the bundled icon.

## Build and test

Requires macOS 13 or later and a Swift 5.9 or newer toolchain. There are no
third-party dependencies.

```sh
swift test
swift run Nariscope
bash build-app.sh
```

`build-app.sh` puts a locally signed `Nariscope.app` in `outputs/` for
the build machine's architecture. It accepts optional output and Swift build
directories as positional arguments. Building the app bundle requires Xcode 26
or later to compile [the Icon Composer artwork](Assets/GopherIcon.icon) into
the macOS app icon.

To start at a particular address, pass a Gopher URL to the executable.

```sh
swift run Nariscope gopher://gopher.floodgap.com/1
```

The Swift tests cover URLs, selector bytes, menu parsing, and rendering. To
exercise a real TCP connection, start the local fixture in one terminal and
run the integration test in another.

```sh
# Terminal 1
python3 Tests/Fixtures/gopher_fixture.py 7070

# Terminal 2
GOPHER_TEST_URL=gopher://127.0.0.1:7070/ GOPHER_TEST_SEARCH=1 swift test
```

## Python prototype

[The prototype](prototype/README.md) contains the crawler, HTML exporter,
evaluation tools, and the reference implementation for the Swift renderer.

```sh
python3 -m unittest discover -s prototype -v
```

For a renderer comparison using a downloaded corpus, generate a parity fixture
and pass its absolute path to Swift.

```sh
python3 prototype/make_parity_fixture.py work/corpus -o work/parity.json
GOPHER_PARITY_FIXTURE="$PWD/work/parity.json" swift test
```

Downloaded pages, generated HTML, and app builds are kept outside Git.

The client connects directly over plaintext Gopher TCP. Menus, text, and
image previews have a 50 MiB limit and a 20-second request timeout. To save a
file, choose **Save…** and pick its destination. Downloads stream to disk
without the preview size limit and time out after 20 seconds without data.
Canceled or failed transfers discard their partial file.
