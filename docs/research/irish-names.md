# Irish names for Todhchai's components

Date: 2026-10-09. Research for open decision 7 in [../roadmap.md](../roadmap.md)
("Component names"). **Decided 2026-10-09:** taisce, loinnir and radharc,
as recommended below.

## How the candidates were checked

- **Meaning:** Ó Dónaill's *Foclóir Gaeilge–Béarla* on teanglann.ie, one
  entry read per word `[V]`; official computing terms from tearma.ie `[V]`.
- **The fada dropped.** Names in code are lowercase ASCII, as `croi` and
  `todhchai` are. Each fada-less form was looked up as a headword, because
  dropping the fada can turn one word into another:
  - `leas` is "benefit, welfare", not léas "ray of light";
  - `fainne` is "weakness, faintness", not fáinne "ring".

  teanglann was overloaded during the check. The fada-less forms of
  seoltóir, treoraí, scrúdú, fiosrú and comhéadan are unverified `[U]`.
- **Pronunciation** guides are rough English approximations, not taken from
  teanglann's recordings `[U]`. They say roughly what a non-speaker would
  hear; check them against the audio at `teanglann.ie/en/fuaim/<word>`.
- **Clashes with existing software:** crates.io, PyPI, npm, Homebrew,
  Debian and GitHub searched for each lowercase name `[V]`. The words added
  late (eolas, seol, bior, barra, fráma, tús, glas, imirt) were checked on
  GitHub only.

## Which components get names

Only components that are new enough that someone would consider
trademarking them get a name. Renaming a familiar thing (a tracer, a
keyring, a taskbar) only to sound different makes the system harder to
learn and buys nothing, so those keep plain descriptive names, as do the
SDK modules (`Loop`, `Window`, `Trace`, …), the services (launcher,
devmgr, router, keyring, tracer, debugd, export bridge, audio, power) and
the `td` tool.

Three components qualify:
- **the file system:** attributes, a query language with live queries, and
  snapshots as directories. Its working name, BeFS-NG, also leans on Be's
  name;
- **the GPU library** (working name Prism): a "No Graphics API"-style
  library over Vulkan, the SDK's way to draw;
- **the compositor:** nestable, plane-first, with late latch and a game
  mode.

UI Kit and Game Kit are borderline: they are the SDK's own designs, and
Apple ships `UIKit` and `GameKit`, so their working names are the
riskier ones. They stay descriptive unless the project decides otherwise.

## Recommendations

| Component | Working name | Recommended | Code | Say | Meaning | Runner-up |
|---|---|---|---|---|---|---|
| File system | BeFS-NG | **taisce** | `taisce` | TASH-keh | store, treasure, a store kept safe; also a term of endearment | stór (`stor` reads as "store", and has same-domain packages) |
| GPU library | Prism | **loinnir** | `loinnir` | LUN-yir | light, brilliance, radiance, sheen | solas, "light" (easy, but hard to search for: SOLAS, Spanish *solas*) |
| Compositor | compositor | **radharc** | `radharc` | RYE-ark | sight; prospect, view, scene | amharc, "sight, view" (mostly Ulster usage) |

## Rejected, and why

| Word | For | Why not |
|---|---|---|
| léas (`leas`) | GPU library | Without the fada it is a different word, "benefit, welfare". Also means "weal, welt". |
| lí (`li`) | GPU library | Also "licking; fawning"; too short to search for. |
| priosma | GPU library | Only a borrowing of "prism". |
| cartlann | file system | "archives": inactive data, not a live, queried store. |
| cuimhne | file system | "memory" suggests RAM; hard to say. |
| fráma (`frama`) | compositor | Reads as Frama-C, the C static-analysis platform. |
| cumadóir | compositor | "composer, maker" but also "fabricator"; long. |

## Clashes kept, knowingly

- **taisce:** a small AI-memory client on PyPI. Outside computing, An Taisce
  is Ireland's National Trust.
- **radharc:** a small Linux display-colour tool (5 stars).
- **loinnir:** none found.

## Words checked for components that keep plain names

The first round also checked words for the components above that now keep
descriptive names. Kept here in case one of them is ever named:

- **Good:**
  - seol, "send, dispatch" (router);
  - eochair, "key" (keyring);
  - rian, "track, trace" (tracer; npm has a small tracing library of that
    name);
  - bior, "probe" (debugger);
  - droichead, "bridge" (export bridge);
  - fréamh, "root" (launcher);
  - fuaim, "sound"; cumhacht, "power";
  - cigire, "inspector"; cluiche, "game"; comhéadan, "interface".
- **Traps:**
  - `fainne` is "faintness" without the fada;
  - `suil` is an LV2 audio library;
  - `clar` is Git's C test framework;
  - `tus` is the tus upload protocol;
  - síol also means "semen".

## Open points

1. Check the pronunciations against teanglann's recordings, and ideally
   with a native speaker, before names reach code.
2. Decide whether user-visible names keep the fada in the UI (Radharc,
   Taisce) while code uses the ASCII form, as Todhchaí and `todhchai` do.
3. Decide whether UI Kit and Game Kit get names, given Apple's `UIKit` and
   `GameKit`.
