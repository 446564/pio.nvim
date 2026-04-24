# pio.nvim

Manual PlatformIO environment switcher for multi-variant projects. Run `:PioEnv`, pick an env (auto-selected if the current file only matches one), and the plugin regenerates `compile_commands.json` for that env and restarts clangd — so the LSP analyzes your code with the right defines, the right arch, and the right include paths.

Built for projects like [MeshCore](https://github.com/ripplebiz/MeshCore) that define hundreds of PlatformIO environments across multiple MCU architectures (ESP32, nRF52, RP2040, STM32) where a single flat `compile_commands.json` can't possibly represent them all at once.

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
  cmd = { "PioEnv", "PioStatus" },
  opts = {
    -- pio_cmd = "pio",
    -- auto_pick_single = true,
    -- always_show_all_envs_as_fallback = true,
  },
  keys = {
    { "<leader>pe", "<cmd>PioEnv<cr>",    desc = "PIO: switch env (from current file)" },
    { "<leader>ps", "<cmd>PioStatus<cr>", desc = "PIO: status for current buffer" },
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
    vim.keymap.set("n", "<leader>pe", "<cmd>PioEnv<cr>",    { desc = "PIO: switch env" })
    vim.keymap.set("n", "<leader>ps", "<cmd>PioStatus<cr>", { desc = "PIO: status" })
  end,
}
```

## Usage

| Keymap | Command | Behavior |
|---|---|---|
| `<leader>pe` | `:PioEnv` | Regenerate for env matching the current file. Auto-picks when only one env matches; otherwise opens a picker grouped as "matches for variants/foo" and "all other envs". |
| — | `:PioEnv <env_name>` | Regenerate for the named env directly. Tab-completes. |
| `<leader>ps` | `:PioStatus` | Print detected variant, arch, and matching envs for the current buffer. |

The `<leader>p` prefix is reserved for future PlatformIO-related commands — add your own under it without worrying about collisions with LazyVim defaults (which uses `<leader>p` only inside tabs/snacks submenus, not as a top-level prefix).

The regeneration runs in a floating window that streams `pio` output live. Dismiss with `<CR>`, `<Esc>`, `q`, or `<Space>` once it finishes. On success, clangd is stopped and re-attached.

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
