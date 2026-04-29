# pio.nvim

A Neovim plugin for [MeshCore](https://github.com/ripplebiz/MeshCore) projects with lots of environments. Pick an env and it regenerates `compile_commands.json` + restarts clangd (so the LSP analyzes your code with the right defines, arch, and includes). Then build, upload, and monitor from the same env without leaving the editor.

Built for [MeshCore](https://github.com/ripplebiz/MeshCore) that define hundreds of PlatformIO environments across multiple MCU architectures (ESP32, nRF52, RP2040, STM32) where a single flat `compile_commands.json` can't possibly represent them all at once.

## Why you'd want this

`clangd` reads `compile_commands.json`. PlatformIO generates one entry per translation unit per environment. If your project has 4+ archs and dozens of variants, you can only ever represent *one* build at a time. When you switch from editing ESP32 code to nRF52 code, clangd is still analyzing with stale flags — wrong defines taken, wrong headers resolved, spurious diagnostics.

Manually running `pio run -t compiledb -e <env>` every time you change focus works. This plugin just makes it a few keystrokes and gets the env right by parsing your `platformio.ini`.

## Requirements

- Neovim 0.8+ (uses `vim.loop.spawn`, `vim.ui.select`, modern LSP API)
- `pio` (PlatformIO core) on `$PATH` — or configure `pio_cmd`
- clangd as your C/C++ LSP

## Install (LazyVim)

```lua
return {
  "446564/pio.nvim",
  ft = { "c", "cpp", "objc", "objcpp" },
  cmd = { "PioEnv", "PioStatus", "PioDevice", "PioBuild", "PioUpload", "PioMonitor" },
  opts = {
    -- pio_cmd = "pio",
    -- auto_pick_single = true,
    -- always_show_all_envs_as_fallback = true,
  },
  keys = {
    { "<leader>pe", "<cmd>PioEnv<cr>",     desc = "PIO: switch env (compile_commands.json)" },
    { "<leader>ps", "<cmd>PioStatus<cr>",  desc = "PIO: status" },
    { "<leader>pd", "<cmd>PioDevice<cr>",  desc = "PIO: select device" },
    { "<leader>pb", "<cmd>PioBuild<cr>",   desc = "PIO: build" },
    { "<leader>pu", "<cmd>PioUpload<cr>",  desc = "PIO: upload" },
    { "<leader>pm", "<cmd>PioMonitor<cr>", desc = "PIO: monitor" },
  },
  init = function()
    -- Register the <leader>p group label for which-key.
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.add({ { "<leader>p", group = "pio" } })
    end
  end,
}
```

**Non-LazyVim lazy.nvim** users: identical spec, just drop the `init` function if you don't use which-key.

**packer.nvim:**

```lua
use {
  "446564/pio.nvim",
  config = function()
    require("pio").setup({})
    local map = function(lhs, cmd, desc)
      vim.keymap.set("n", lhs, "<cmd>" .. cmd .. "<cr>", { desc = desc })
    end
    map("<leader>pe", "PioEnv",     "PIO: switch env")
    map("<leader>ps", "PioStatus",  "PIO: status")
    map("<leader>pd", "PioDevice",  "PIO: select device")
    map("<leader>pb", "PioBuild",   "PIO: build")
    map("<leader>pu", "PioUpload",  "PIO: upload")
    map("<leader>pm", "PioMonitor", "PIO: monitor")
  end,
}
```

## Usage

| Keymap | Command | Behavior |
|---|---|---|
| `<leader>pe` | `:PioEnv [name]` | Set the target env and regenerate `compile_commands.json` for it. Auto-picks when only one env matches the current file; otherwise opens a picker. |
| `<leader>ps` | `:PioStatus` | Show session state (target env, device, last compiled env) and the current file's variant/arch/matching-envs. |
| `<leader>pd` | `:PioDevice` | Run `pio device list` and pick an upload port. Stored in session state and used by `:PioUpload`/`:PioMonitor`. Pick "clear selection" to fall back to pio's auto-detection. |
| `<leader>pb` | `:PioBuild [name]` | Build the target env (`pio run -e <env>`). If no env is set, resolves from current file or prompts. |
| `<leader>pu` | `:PioUpload [name]` | Upload the target env (`pio run -t upload -e <env>`), to the selected device if one is set (`--upload-port`). |
| `<leader>pm` | `:PioMonitor [name]` | Open `pio device monitor` in a bottom split. Focus stays in your code window. Press `q` in the monitor to stop it and close the split; the serial port is always released when the buffer goes away. |

All three build/upload/monitor commands share **env resolution**: they use the target env (set by `:PioEnv` or by a previous picker choice), or fall back to the current file's single-match env, or prompt with the picker. The picker stores your choice as the new target, so subsequent commands in the same session are one-keystroke.

The `<leader>p` prefix is reserved for PlatformIO-related commands — add your own under it without collisions with LazyVim defaults (which don't use `<leader>p` as a top-level group).

The build/upload/compile_commands runs appear in a floating window that streams `pio` output live. Dismiss with `<CR>`, `<Esc>`, `q`, or `<Space>` once the process exits.

## How file-to-env mapping works

The plugin parses `platformio.ini` and every `variants/*/platformio.ini`, resolving `extends =` chains (including multi-line form) to build a full list of environments with their detected arch and variant folder(s). An env is considered to "belong to" a variant if any of:

1. Its flattened `build_flags` contain `-I variants/<n>`, or
2. It's defined in `variants/<n>/platformio.ini` itself.

Arch is detected from `-D ESP32_PLATFORM` / `NRF52_PLATFORM` / `RP2040_PLATFORM` / `STM32_PLATFORM` defines.

Given the current buffer path:

- If under `variants/<n>/...`, envs matching that variant score highest (100 pts each).
- If under `src/helpers/<arch>/...`, envs matching that arch score second (10 pts).
- Otherwise no match — the picker shows the full env list as fallback.

## Configuration

Defaults shown:

```lua
require("pio").setup({
  pio_cmd = "pio",
  auto_pick_single = true,  -- skip picker when only one env matches
  always_show_all_envs_as_fallback = true,
})
```

## Known limitations

- Generic files under `src/` (like `Dispatcher.cpp`) don't have a natural "home" env — you'll always get the picker. That's fine, just pick the env for whichever target you're actively debugging.
- The plugin doesn't cache or queue regenerations. If you run the command twice quickly, two `pio` processes will run. PlatformIO handles this okay but it's wasteful.
- Multi-line `extends = \n  a\n  b` is supported. Space-separated `extends = a b` is also supported. Mixed (e.g. `extends = a` followed by indented `b`) will parse as `a b` — PlatformIO also accepts this, so it matches.
- Only reads `.ini` files at `setup()` time; re-reads automatically when their mtime changes. Hot-editing `platformio.ini` in another neovim instance while this plugin is running will pick up changes on the next `:PioEnv` call.

## Troubleshooting

**"no platformio.ini found above ..."** — Your buffer isn't under a PlatformIO project. The plugin walks up from the current file (or cwd) looking for `platformio.ini`.

**`pio` not found / spawn failed** — Set `pio_cmd = "/path/to/pio"` in setup, or use `platformio` if that's your binary name.

**clangd doesn't pick up the new DB** — The plugin stops all clangd clients and re-`:edit`s the buffer to re-attach. If your LSP setup uses something more exotic (multiple clangd instances, project-specific wrappers), you may need to `:LspRestart` manually.

**Wrong env keeps being picked for generic files** — That's expected; generic files have no arch/variant signal. Use `:PioStatus` to see what the plugin detected, or pass the env explicitly: `:PioEnv MyEnvName`.
