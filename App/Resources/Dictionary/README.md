# Bundled English–Korean dictionary

The dictionary data in `en-ko.sqlite` is licensed under **Creative Commons
Attribution-ShareAlike 4.0 International**, independently of Bandal's MIT-licensed
application code. The complete license is in `LICENSE-CC-BY-SA-4.0.txt`.

## Sources and attribution

- English Wiktionary contributors: https://en.wiktionary.org/
- Kaikki / Wiktextract, Tatu Ylonen and contributors: https://kaikki.org/ and
  https://github.com/tatuylonen/wiktextract
- Daniel Gregorini / koreader-dicts contributors, English–Korean compilation
  v1.2.0: https://github.com/DanielGregorini/koreader-dicts/releases/tag/v1.2.0
- Princeton University WordNet 3.0, Copyright 2006 by Princeton University,
  used by the upstream compilation for inflection exceptions. Its complete
  notice is preserved in `LICENSE-WordNet-3.0.txt`:
  https://wordnet.princeton.edu/license-and-commercial-use

`UPSTREAM-ATTRIBUTION.txt` preserves the upstream archive's attribution.
Each entry also preserves its original Wiktionary page URL, which links to the
page history listing its contributors. The app shows this source when reading
or saving a dictionary meaning.

## Bandal's modifications

StarDict HTML was converted into structured Korean meanings, English definitions,
pronunciation, and translated part-of-speech labels. Lookup keys and inflection
references were normalized and indexed in a read-only SQLite database. No
translations were generated. The adapted dictionary remains CC BY-SA 4.0.

The source URL and archive SHA-256, generated database SHA-256, schema version,
and measured counts are recorded in `manifest.json`. These resources are
committed and included in macOS and Windows packages; release builds and app
lookups never download or generate dictionary data.

To regenerate with the project's Node 24 dependencies:

```sh
node scripts/build-dictionary.mjs
# Or reuse the pinned archive without a network request:
node scripts/build-dictionary.mjs --archive /path/to/en-ko.zip
```

The importer verifies the pinned archive hash before parsing. Review the database
and manifest changes together, and preserve every license and attribution file.
The dictionary has incomplete vocabulary and sense coverage; missing words use
the reader's explicit external-dictionary action, without automatic AI fallback.
