# OneReader App Icon

The 1024 px master is the source artwork for every macOS, iPhone, and iPad icon
slot. Do not edit generated files inside the asset catalog by hand; run
`scripts/generate-app-icons.sh` after replacing the master.

## Visual idea

- Layered teal pages represent heterogeneous sources aligned into one reader.
- The warm central spine is both a reading path and a subtle numeral one.
- The midnight blue field keeps the mark calm and legible in light and dark UI.
- There is no text, platform chrome, or baked corner mask.

## Generation prompt

> Create a premium Apple-platform app icon for OneReader, a calm all-in-one
> reading library. Use a full square midnight navy background with no baked
> rounded corners. Center a bold, symmetric open book made from layered deep
> teal and sea-green pages. A warm ivory-to-gold luminous vertical reading path
> should rise through the book's center and subtly suggest the numeral one.
> Keep the silhouette simple and recognizable at 16 px, with refined native
> depth, restrained highlights, no text, no letters, no border, and no device
> mockup.

The master was generated with the built-in image generation model, then resized
deterministically with `sips`. The script also builds the macOS `.icns` file.
