# RasterNest for AI agents and scripts

RasterNest's CLI is built so a script or an AI agent can write documentation screenshots without doing pixel math:

1. **Capture** a window by app name.
2. **Read** where the text is with `rnest ocr --json`.
3. **Annotate** by naming what's on screen: "step 1 on *Save*, arrow to *Allow*, redact emails".
4. **Rebuild** a whole guide with `rnest guide run` when the UI changes.

All four are also available to Claude and other agents through the MCP server, `rnest mcp`.

Coordinates are always **image pixels, origin top-left**. A Retina capture is twice the size of the screen points it shows. `rnest ocr --json` reports the image's `scale`.

## OCR with positions

```sh
rnest ocr shot.png --json            # lines, each with a box and its words
rnest ocr shot.png --find "Save"     # best match only: {"x":…, "y":…, "width":…, "height":…}
rnest ocr shot.png --find "Save" --all
```

`--json` prints:

```json
{
  "width": 3024, "height": 1964, "scale": 2,
  "lines": [
    { "text": "Save changes", "confidence": 1,
      "box": { "x": 120, "y": 88, "width": 210, "height": 34 },
      "words": [ { "text": "Save", "box": { … } }, { "text": "changes", "box": { … } } ] }
  ]
}
```

On macOS it uses Apple's Vision framework. On Linux it uses `tesseract` (`sudo apt install tesseract-ocr`).

## Annotation specs

Quick markup with flags:

```sh
rnest annotate shot.png --step "Save" --step "Allow" --box "Advanced" --arrow "Apply" \
  --highlight "Beta" --redact email --redact "Jane Doe" --frame docs -o step.png
```

- `--redact` accepts a pattern name (`email`, `phone`, `ipv4`, `url`, `card`, `token`). Anything else is treated as literal text to hide.
- Output is `<input>-annotated.png` unless you pass `-o`. Use `-o file.rasternest` to keep the result editable in the app. `-e` opens the result in the editor.

For anything more, write a spec (JSON) and pass it with `--spec file.json`, or `--spec -` to read it from stdin:

```json
{
  "frame": "docs",
  "color": "red",
  "annotations": [
    { "type": "step",      "at": { "text": "Save" }, "label": "Click Save" },
    { "type": "arrow",     "to": { "text": "Allow" } },
    { "type": "arrow",     "from": { "x": 900, "y": 120 }, "to": { "text": "Allow", "occurrence": 2 } },
    { "type": "box",       "around": { "text": "Advanced" }, "padding": 10 },
    { "type": "ellipse",   "around": { "rect": [40, 80, 300, 60] }, "color": "#0EA5E9" },
    { "type": "highlight", "around": { "text": "Beta" } },
    { "type": "text",      "text": "New in 2.0", "at": { "text": "Export" } },
    { "type": "spotlight", "around": { "text": "Preferences" } },
    { "type": "magnify",   "around": { "rect": [10, 10, 120, 80] }, "zoom": 2.5 },
    { "type": "pixelate",  "around": { "text": "Account ID" } },
    { "type": "redact",    "pattern": "email" },
    { "type": "redact",    "regex": "sk-[A-Za-z0-9]{20,}" },
    { "type": "redact",    "match": "Jane Doe" }
  ]
}
```

### Anchors

An anchor says where something goes. Use one of these forms:

| Anchor | Meaning |
|---|---|
| `{"text": "Save"}` | Found by OCR, case-insensitive. A whole line that matches wins first, then whole words inside a line, then a partial match. Bullets and trailing `…` or `:` are ignored. |
| `{"text": "Save", "occurrence": 2}` | The second match. |
| `{"x": 120, "y": 80}` | A point. |
| `{"rect": [x, y, w, h]}` | A rectangle. |

If the text isn't found, the command fails and lists the text it did see, so an agent can correct itself.

### Types

| Type | Fields | Placement |
|---|---|---|
| `step` | `at`, `number`, `label` | Numbered circle to the left of the anchor (right if there's no room). Numbers continue from existing steps. |
| `arrow`, `line` | `to`, `from`, `label` | Without `from`, the arrow starts diagonally from the side facing the middle of the image. It ends on the target's edge. |
| `box` (`rectangle`), `ellipse`, `highlight` | `around`, `padding`, `filled`, `label` | Surrounds the anchor. |
| `text` | `text`, `at`, `callout` | A filled callout below the anchor, or above it when it's near the bottom. |
| `pixelate`, `spotlight`, `magnify` | `around`, `zoom` | |
| `redact` | `pattern`, `regex`, `match`, or `around` | Pixelates every match. |

Every type also accepts `color` (a name, or `#RRGGBB`), `width` (line width in points), `size` (font size in points) and `padding` (in points). Sizes in points scale with the image, so Retina captures look the same as standard ones.

`frame` is `none` or `docs`: padding, a soft gradient, rounded corners and a shadow.

## Guides

A guide is a list of steps. Each step has a capture and its markup. `rnest guide run` captures and annotates every step, then writes the images, a Markdown page and (optionally) a PDF. When the UI changes, run it again and every screenshot updates.

```sh
rnest guide init dark-mode.json        # starter file
rnest guide run dark-mode.json
rnest guide run dark-mode.json --step appearance   # rebuild one step
```

```json
{
  "title": "Turn on dark mode",
  "output": "img",
  "frame": "docs",
  "markdown": "dark-mode.md",
  "pdf": "dark-mode.pdf",
  "steps": [
    {
      "name": "appearance",
      "caption": "Open **System Settings › Appearance**.",
      "before": "open 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'",
      "wait": 2,
      "capture": { "app": "System Settings" },
      "annotations": [
        { "type": "step", "at": { "text": "Appearance" } },
        { "type": "box", "around": { "text": "Dark" }, "label": "Choose Dark" }
      ]
    },
    {
      "name": "existing",
      "caption": "Steps can also annotate an image you already have.",
      "capture": { "file": "screens/old.png" },
      "annotations": [ { "type": "redact", "pattern": "email" } ]
    }
  ]
}
```

**Capture options**

| Option | What it captures |
|---|---|
| `{"app": "Safari"}` | Safari's front window. Add `"title"` to pick a window by its title. |
| `{"window": "Invoices"}` | The front-most window whose app name or title contains "Invoices". |
| `{"rect": [x, y, w, h]}` | An area, in screen points. |
| `{"fullscreen": true, "display": 0}` | A whole display. |
| `{"file": "path.png"}` | An existing image, path relative to the guide. |

**Other step fields**

- `before`: a shell command that runs in the guide's folder, e.g. opening a URL or an app.
- `wait`: seconds to pause before capturing.

**What gets written**

- For each step, `NN-name.png` and an editable `NN-name.rasternest` in `output`. The default folder is `<guide>-images`.
- The Markdown file. Its default name is `<guide>.md`; set `"markdown": ""` to skip it.
- `pdf`, if you set it.

## MCP server

`rnest mcp` serves the [Model Context Protocol](https://modelcontextprotocol.io) over stdio.

**Claude Code**

```sh
claude mcp add rasternest -- rnest mcp
```

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`)

```json
{ "mcpServers": { "rasternest": { "command": "/opt/homebrew/bin/rnest", "args": ["mcp"] } } }
```

Use the full path that `which rnest` prints. If you installed from the DMG, choose **Install Command Line Tool…** in the RasterNest menu first; that puts `rnest` in `/usr/local/bin/rnest`.

**Tools**

| Tool | What it does |
|---|---|
| `capture` | Captures a window by `app`/`title`, a `window_id`, a `rect`, a whole display, or lets the user pick (`interactive`). Returns the path, the size and a preview image. |
| `ocr` | Text with boxes for an image. `find` returns just one piece of text. |
| `annotate` | Applies a list of spec annotations. Saves a PNG and an editable `.rasternest`, and returns a preview. |
| `export` | Flattens to PNG/JPEG, combines captures into a PDF, or converts an MP4 to GIF. |
| `run_guide` | Builds or rebuilds a guide file. |
| `list_windows`, `list_displays` | What's on screen. |
| `open_in_editor` | Hands a file to the RasterNest app so you can fine-tune it. |

Captures from the MCP server go to `~/Pictures/RasterNest/agent/` unless the agent passes a path. Preview images are scaled to at most 1568 px on the long side; annotation coordinates always refer to the full-size image.

**Permissions.** On macOS, Screen Recording permission belongs to the app that starts `rnest`: your terminal for Claude Code, and Claude for Claude Desktop. The first capture triggers the prompt. If capture fails, allow that app in System Settings › Privacy & Security › Screen & System Audio Recording.

**A prompt that works well**

> Use RasterNest to document how to create a new project in our dashboard. Open it in Safari, capture the window at each step, put numbered steps on what to click, redact emails and tokens, use the docs frame, and save a guide file so we can rebuild it later.

## Platform notes

| | macOS | Linux |
|---|---|---|
| `ocr --json` | Vision | tesseract |
| `annotate` → `.rasternest` | ✓ | ✓ |
| `annotate` → `.png`/`.jpg` | ✓ | not yet |
| `guide run` | ✓ | not yet (needs PNG rendering) |
| `mcp` | ✓ | ✓ (no preview images) |
