# Lightroom Classic Plugin: Lychee

A publish service plugin for Adobe Lightroom Classic that synchronizes photos to a [Lychee](https://lychee.electerious.com/) photo gallery. Each publish service gets its own connection (you can connect to several Lychee instances).

## Features

### Publishing

- **Published Collections** — each collection maps to an album on Lychee
- **Published Collection Sets** — nested collection sets map to nested albums, maintaining your folder hierarchy
- **Photo upload** with automatic duplicate detection (skips photos already in the album)
- **Metadata sync** — title, caption/description, and tags are pushed to Lychee on publish
- **Republish on change** — editing a photo or changing its title/caption marks it for republish
- **File renaming** — use Lightroom's File Naming options to control the uploaded filename
- **Image sizing, sharpening, and metadata stripping** via standard Lightroom export panels

### Collection & Album Management

- **Create, rename, and delete** collections and collection sets from Lightroom
- **Move detection** — moving a photo between collections in Lightroom will relocate it to the correct album on Lychee (delete + re-upload)
- **Album settings** — edit album properties directly from Lightroom's "Edit Published Collection" dialog:
  - Description, copyright, and license
  - Photo and album sorting (column and order)
  - Layout, aspect ratio, and timeline settings
  - Header image selection (default, compact, or a specific album photo)
  - Visibility and access controls: public/private, NSFW, link-required, full-size access, download permission, password protection
- **"Go to Collection" URL** — right-click a collection and open it directly in your Lychee gallery

### Connection

- **Multiple instances** — add several publish services to connect to different Lychee galleries
- **API token auth** — uses Bearer token authentication (generate a token under "Edit My User" in Lychee)
- **Test Connection** button to verify your gallery URL and token

## Getting Started

1. Install Adobe Lightroom Classic.
2. Copy the `LrLychee.lrdevplugin` folder to the Lightroom plugins directory (or add it via File > Plug-in Manager > Add).
3. Enable the plugin in Lightroom Classic.
4. Under Publishing Manager, add a **Lychee Gallery** publish service — set the gallery URL and API token.
5. Create a Published Collection, add photos, and click Publish.

## Requirements

- Adobe Lightroom Classic
- Lychee v7.x

## Caveats

- The code here is generated with AI assistance (Claude, Copilot, etc.) — my Lua skills and the state of the Adobe documentation combined are not great :P
- Only tested against Lychee v7.x
