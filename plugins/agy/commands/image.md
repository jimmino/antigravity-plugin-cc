---
description: Generate an image with Antigravity CLI (uses agy's built-in generate_image tool — Imagen under the hood)
argument-hint: "[--name <slug>] [--output <path>] <description>"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" image *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" image *)']
---

Ask `agy` to generate an image. The Antigravity CLI ships a native
`generate_image` tool (Imagen under the hood) that triggers automatically
when the prompt asks for an image — the wrapper builds the right prompt and
extracts the saved file path.

The user's request (treat as opaque — pass through as shell-safe
arguments):

```
$ARGUMENTS
```

## How to invoke

Parse the user's request into three parts:

- `--name <slug>` — optional. Filename slug `agy` should save the image
  under (no extension).
- `--output <path>` — optional. Local path the wrapper should copy the
  generated file to after `agy` finishes.
- The remaining text — the description of what to generate.

Use the `Bash` tool to run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" image "<description>" [--name <slug>] [--output <path>]
```

…with the description quoted as one shell argument so characters like `"`,
`$`, `;` cannot break out.

## How the wrapper finds the saved path

The wrapper builds a prompt that asks `agy` to end its reply with a single
line:

```
IMAGE_PATH: <absolute path to the generated image>
```

This is the **primary contract**. If `agy` honors it, the wrapper picks the
path up deterministically and (when `--output` is set) copies the file
there. As a fallback, the wrapper also scrapes any absolute `*.png/.jpg/.jpeg/.webp`
path that appears in `agy`'s reply.

If neither is found, the wrapper prints a clear warning so the user knows the
file wasn't located. Generated files normally live under
`~/.gemini/antigravity-cli/brain/<uuid>/<name>.<ext>`.

## Notes

- Return Antigravity's full text response verbatim so the user can see the
  generated path.
- If the user did not provide any description, ask what they want to
  generate.
- If the wrapper reports `agy is not installed` or `not authenticated`,
  stop and tell the user to run `/agy:setup`.
