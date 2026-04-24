-- pio.nvim
-- Manual PlatformIO env switcher for multi-variant projects.
-- Maps the current buffer's file to candidate envs by parsing
-- platformio.ini + variants/*/platformio.ini, then regenerates
-- compile_commands.json for the chosen env and restarts clangd.

local M = {}

local config = {
	-- Command to invoke PlatformIO. Override if you use `pio` via pipx,
	-- a project-local venv, etc.
	pio_cmd = "pio",
	-- If true, when only one env matches the current file, use it
	-- without prompting. When false, always show the picker.
	auto_pick_single = true,
	-- Extra keywords to always show in the picker as a fallback
	-- (useful when the file isn't under any variant, e.g. shared src/).
	-- The plugin will also add all envs as fallback.
	always_show_all_envs_as_fallback = true,
}

local state = {
	root = nil, -- project root (dir containing platformio.ini)
	envs = nil, -- cached list of { name, variant_dir, archs, ini_path }
	envs_mtime = nil, -- aggregate mtime of ini files when parsed
	last_env = nil, -- last env we regenerated compile_commands.json for
	-- Session-only (wiped on nvim restart):
	target_env = nil, -- env for build/upload/monitor; set by :PioEnv or picker
	device = nil, -- upload port (e.g. /dev/ttyUSB0); nil = pio auto-detect
}

-- ---------------------------------------------------------------------------
-- utilities
-- ---------------------------------------------------------------------------

local function notify(msg, level)
	vim.notify("[pio] " .. msg, level or vim.log.levels.INFO)
end

local function find_root(start)
	-- Walk up from `start` collecting EVERY directory that contains a
	-- platformio.ini, then return the topmost one. This matters for
	-- projects like MeshCore where each variants/<name>/ has its own
	-- platformio.ini that is `extra_configs`-included by the real root.
	-- Without this, opening a file under variants/foo/ would pick
	-- variants/foo/ as the root and PlatformIO would fail with
	-- "No section: 'esp32_base'" because it only sees the variant file.
	local cur = vim.fn.fnamemodify(start, ":p")
	if vim.fn.isdirectory(cur) == 0 then
		cur = vim.fn.fnamemodify(cur, ":h")
	end
	-- Strip trailing slash so fnamemodify(":h") actually moves up a level.
	cur = cur:gsub("/+$", "")
	local candidates = {}
	for _ = 1, 40 do
		if vim.fn.filereadable(cur .. "/platformio.ini") == 1 then
			table.insert(candidates, cur)
		end
		local parent = vim.fn.fnamemodify(cur, ":h")
		if parent == cur or parent == "" then
			break
		end
		cur = parent
	end
	-- Topmost (last pushed) is the real project root.
	return candidates[#candidates]
end

local function file_mtime(path)
	local stat = vim.loop.fs_stat(path)
	return stat and stat.mtime.sec or 0
end

-- ---------------------------------------------------------------------------
-- .ini parsing
--
-- We only need two things per env:
--   1. its name (from [env:NAME] headers)
--   2. which variant folder(s) and arch it belongs to
--
-- PlatformIO's inheritance (extends = X) and shared arch_base sections
-- (esp32_base, nrf52_base, ...) make this non-trivial. We don't try to
-- fully evaluate PlatformIO's config -- we just collect enough to decide
-- "does file F plausibly belong to env E?".
--
-- Strategy:
--   - Parse all sections from platformio.ini and variants/*/platformio.ini.
--   - For each [env:NAME], resolve its build_flags transitively via
--     `extends = ...`, looking for:
--       * `-I variants/<name>`  -> variant directory
--       * `-D ESP32_PLATFORM` / `NRF52_PLATFORM` / `RP2040_PLATFORM` /
--         `STM32_PLATFORM`      -> arch
--   - Record which ini file the env lives in; its parent dir (if under
--     variants/) is a strong signal too.
-- ---------------------------------------------------------------------------

local ARCH_DEFINES = {
	ESP32_PLATFORM = "esp32",
	NRF52_PLATFORM = "nrf52",
	RP2040_PLATFORM = "rp2040",
	STM32_PLATFORM = "stm32",
}

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

-- Returns: { [section_name] = { extends = "...", raw_lines = {...} }, ... }
-- and a list of ini file paths that were read (for mtime tracking).
local function parse_ini_files(root)
	local sections = {}
	local ini_paths = { root .. "/platformio.ini" }

	-- Collect variants/*/platformio.ini too. We don't rely on extra_configs
	-- being set correctly -- we just glob.
	local variant_dir = root .. "/variants"
	if vim.fn.isdirectory(variant_dir) == 1 then
		for _, entry in ipairs(vim.fn.readdir(variant_dir)) do
			local candidate = variant_dir .. "/" .. entry .. "/platformio.ini"
			if vim.fn.filereadable(candidate) == 1 then
				table.insert(ini_paths, candidate)
			end
		end
	end

	-- Also honor a platformio.local.ini if present.
	local local_ini = root .. "/platformio.local.ini"
	if vim.fn.filereadable(local_ini) == 1 then
		table.insert(ini_paths, local_ini)
	end

	for _, path in ipairs(ini_paths) do
		local content = read_file(path)
		if content then
			local current
			-- PlatformIO allows both
			--   extends = a b
			-- and
			--   extends =
			--      a
			--      b
			-- so we must fold indented continuation lines back into the
			-- extends value until a new key or section starts.
			local in_extends = false
			local extends_acc = ""

			local function flush_extends()
				if current and extends_acc ~= "" then
					local trimmed = extends_acc:gsub("^%s+", ""):gsub("%s+$", "")
					sections[current].extends = trimmed:gsub("%s+", " ")
				end
				in_extends = false
				extends_acc = ""
			end

			for line in content:gmatch("[^\r\n]+") do
				local header = line:match("^%s*%[([^%]]+)%]%s*$")
				if header then
					flush_extends()
					current = header
					sections[current] = sections[current]
						or {
							ini_path = path,
							raw_lines = {},
							extends = nil,
						}
				elseif current then
					local is_indented = line:match("^%s") ~= nil
					local key, val = line:match("^%s*([%w_%-%.]+)%s*=%s*(.*)$")

					if key == "extends" then
						flush_extends()
						in_extends = true
						extends_acc = val or ""
					elseif key then
						-- Any other new key terminates an in-progress extends block.
						flush_extends()
					elseif in_extends and is_indented then
						extends_acc = extends_acc .. " " .. line
					end

					table.insert(sections[current].raw_lines, line)
				end
			end

			flush_extends()
		end
	end

	return sections, ini_paths
end

-- Walk a section's inheritance chain, collecting every raw line from
-- every ancestor. Cycle-safe. Returns a flat list of lines.
local function collect_inherited_lines(sections, name, seen)
	seen = seen or {}
	if seen[name] then
		return {}
	end
	seen[name] = true
	local sec = sections[name]
	if not sec then
		return {}
	end

	local lines = {}
	if sec.extends then
		-- Handle space-separated multi-extends (rare but legal).
		for parent in sec.extends:gmatch("%S+") do
			for _, l in ipairs(collect_inherited_lines(sections, parent, seen)) do
				table.insert(lines, l)
			end
		end
	end
	for _, l in ipairs(sec.raw_lines) do
		table.insert(lines, l)
	end
	return lines
end

-- Derive archs + variant dir from a flat list of lines.
local function classify_lines(lines)
	local info = { archs = {}, variants = {} }
	for _, l in ipairs(lines) do
		-- Match both "-D FOO" and "-DFOO".
		for define in l:gmatch("%-D%s*([%w_]+)") do
			local arch = ARCH_DEFINES[define]
			if arch then
				info.archs[arch] = true
			end
		end
		-- Variant include: "-I variants/<name>" or "-Ivariants/<name>".
		local variant = l:match("%-I%s*variants/([%w_%-]+)")
		if variant then
			info.variants[variant] = true
		end
	end
	return info
end

-- Build the authoritative env list.
local function build_env_list(root)
	local sections, ini_paths = parse_ini_files(root)
	local envs = {}

	for name, sec in pairs(sections) do
		local env_name = name:match("^env:(.+)$")
		if env_name then
			local lines = collect_inherited_lines(sections, name)
			local info = classify_lines(lines)

			-- Hint from file location: if the [env:X] is defined inside
			-- variants/<folder>/platformio.ini, that folder is a strong match
			-- even if no `-I variants/<folder>` appears in build_flags.
			local folder_hint = sec.ini_path:match("/variants/([^/]+)/platformio%.ini$")
			if folder_hint then
				info.variants[folder_hint] = true
			end

			table.insert(envs, {
				name = env_name,
				archs = vim.tbl_keys(info.archs),
				variants = vim.tbl_keys(info.variants),
				ini_path = sec.ini_path,
			})
		end
	end

	table.sort(envs, function(a, b)
		return a.name < b.name
	end)
	return envs, ini_paths
end

-- Cache-aware env list accessor.
local function get_envs(root)
	local sections, ini_paths = parse_ini_files(root)
	local _ = sections

	local max_mtime = 0
	for _, p in ipairs(ini_paths) do
		local m = file_mtime(p)
		if m > max_mtime then
			max_mtime = m
		end
	end

	if state.envs and state.envs_mtime == max_mtime then
		return state.envs
	end

	local envs = build_env_list(root)
	state.envs = envs
	state.envs_mtime = max_mtime
	return envs
end

-- ---------------------------------------------------------------------------
-- file -> candidate envs
-- ---------------------------------------------------------------------------

-- Given an absolute file path and the project root, determine the relevant
-- variant folder and/or arch, and return a list of envs ranked by relevance.
local function rank_envs_for_file(root, abs_file, envs)
	local rel = abs_file:sub(#root + 2) -- strip root + leading "/"

	local file_variant = rel:match("^variants/([^/]+)/")
	local file_arch
	-- src/helpers/<arch>/... is a strong arch signal.
	local helper_arch = rel:match("^src/helpers/([^/]+)/")
	if
		helper_arch
		and (helper_arch == "esp32" or helper_arch == "nrf52" or helper_arch == "stm32" or helper_arch == "rp2040")
	then
		file_arch = helper_arch
	end

	local ranked = {}
	for _, env in ipairs(envs) do
		local score = 0
		if file_variant then
			for _, v in ipairs(env.variants) do
				if v == file_variant then
					score = score + 100
					break
				end
			end
		end
		if file_arch then
			for _, a in ipairs(env.archs) do
				if a == file_arch then
					score = score + 10
					break
				end
			end
		end
		table.insert(ranked, { env = env, score = score })
	end

	table.sort(ranked, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.env.name < b.env.name
	end)

	-- Separate "matched" from "fallback" envs so the picker can group them.
	local matched, fallback = {}, {}
	for _, r in ipairs(ranked) do
		if r.score > 0 then
			table.insert(matched, r.env)
		else
			table.insert(fallback, r.env)
		end
	end

	return {
		matched = matched,
		fallback = fallback,
		file_variant = file_variant,
		file_arch = file_arch,
	}
end

-- ---------------------------------------------------------------------------
-- floating progress window
-- ---------------------------------------------------------------------------

local function open_progress_window(title)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "pio")

	local width = math.min(90, math.floor(vim.o.columns * 0.7))
	local height = math.min(20, math.floor(vim.o.lines * 0.5))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})

	local lines = {}

	local function append(text)
		-- Handle embedded newlines.
		for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
			table.insert(lines, line)
		end
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { #lines, 0 })
		end
	end

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	return { append = append, close = close, buf = buf, win = win }
end

-- ---------------------------------------------------------------------------
-- compiledb runner
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- generic pio runner
--
-- Spawns `pio <args...>` in `root`, streams stdout+stderr into a progress
-- window, and calls on_done(exit_code) when finished. The window becomes
-- dismissible (any of <CR>/<Esc>/q/<Space>) only after the process exits,
-- so users can't accidentally close it mid-run.
-- ---------------------------------------------------------------------------

local function make_dismissible(progress)
	for _, key in ipairs({ "<CR>", "<Esc>", "q", "<Space>" }) do
		vim.keymap.set("n", key, function()
			progress.close()
		end, { buffer = progress.buf, silent = true, nowait = true })
	end
end

local function run_pio(opts)
	-- opts: { root, args, title, on_done }
	local progress = open_progress_window(opts.title)
	progress.append("$ " .. config.pio_cmd .. " " .. table.concat(opts.args, " "))
	progress.append("  cwd: " .. opts.root)
	progress.append("")

	local stdout = vim.loop.new_pipe(false)
	local stderr = vim.loop.new_pipe(false)
	local handle
	local start_time = vim.loop.hrtime()

	local function on_read(_, data)
		if data then
			vim.schedule(function()
				progress.append(data:gsub("\n$", ""))
			end)
		end
	end

	handle = vim.loop.spawn(config.pio_cmd, {
		args = opts.args,
		cwd = opts.root,
		stdio = { nil, stdout, stderr },
	}, function(code, _)
		stdout:close()
		stderr:close()
		handle:close()
		local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
		vim.schedule(function()
			progress.append("")
			progress.append(string.format("--- exit code %d (%.1fs) ---", code, elapsed_ms / 1000))
			if code == 0 then
				progress.append("Press any key to close.")
			else
				progress.append("FAILED. Press any key to close.")
			end
			make_dismissible(progress)
			vim.api.nvim_set_current_win(progress.win)
			if opts.on_done then
				opts.on_done(code)
			end
		end)
	end)

	if not handle then
		progress.append("ERROR: failed to spawn `" .. config.pio_cmd .. "`")
		progress.append("Is PlatformIO installed and on $PATH?")
		make_dismissible(progress)
		if opts.on_done then
			opts.on_done(-1)
		end
		return
	end

	stdout:read_start(on_read)
	stderr:read_start(on_read)
	return progress
end

-- ---------------------------------------------------------------------------
-- compiledb runner (thin wrapper on run_pio)
-- ---------------------------------------------------------------------------

local function run_compiledb(root, env_name, on_done)
	run_pio({
		root = root,
		args = { "run", "-t", "compiledb", "-e", env_name },
		title = "Regenerating compile_commands.json [" .. env_name .. "]",
		on_done = function(code)
			if code == 0 then
				state.last_env = env_name
			end
			if on_done then
				on_done(code)
			end
		end,
	})
end
local function restart_clangd()
	local clients
	if vim.lsp.get_clients then
		clients = vim.lsp.get_clients({ name = "clangd" })
	else
		clients = vim.lsp.get_active_clients({ name = "clangd" })
	end
	-- Capture every buffer clangd was attached to BEFORE stopping it,
	-- so we can re-trigger LspAttach on all of them -- not just whichever
	-- buffer happens to be focused (which might be our progress window).
	local attached_bufs = {}
	for _, c in ipairs(clients) do
		for bufnr, _ in pairs(c.attached_buffers or {}) do
			attached_bufs[bufnr] = true
		end
		c.stop()
	end

	vim.defer_fn(function()
		for bufnr, _ in pairs(attached_bufs) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				local name = vim.api.nvim_buf_get_name(bufnr)
				if name ~= "" and vim.fn.filereadable(name) == 1 then
					-- `:edit` without a buffer context needs the buffer current.
					-- buf_call runs the callback in that buffer's context safely.
					pcall(vim.api.nvim_buf_call, bufnr, function()
						vim.cmd("edit")
					end)
				end
			end
		end
	end, 500)
end

-- ---------------------------------------------------------------------------
-- picker
-- ---------------------------------------------------------------------------

local function pick_env(ranked, callback)
	local items = {}
	local display = {}

	if #ranked.matched > 0 then
		table.insert(
			display,
			"── matches for "
				.. (ranked.file_variant and ("variants/" .. ranked.file_variant) or (ranked.file_arch and ("arch: " .. ranked.file_arch)) or "this file")
				.. " ──"
		)
		for _, env in ipairs(ranked.matched) do
			table.insert(items, env.name)
			table.insert(display, "  " .. env.name)
		end
	end

	if config.always_show_all_envs_as_fallback and #ranked.fallback > 0 then
		table.insert(display, "── all other envs ──")
		for _, env in ipairs(ranked.fallback) do
			table.insert(items, env.name)
			table.insert(display, "  " .. env.name)
		end
	end

	if #items == 0 then
		notify("no PlatformIO envs found", vim.log.levels.WARN)
		return
	end

	-- Strip separator lines in what we pass to vim.ui.select's `items`,
	-- but use `format_item` to render the grouped view. vim.ui.select
	-- doesn't natively support separators, so we fake it by including
	-- them as unselectable entries that just re-open the picker.
	vim.ui.select(display, {
		prompt = "Select PlatformIO env:",
		format_item = function(i)
			return i
		end,
	}, function(choice)
		if not choice then
			return
		end
		if choice:match("^──") then
			-- user tapped a separator; re-show.
			pick_env(ranked, callback)
			return
		end
		callback(vim.trim(choice))
	end)
end

-- ---------------------------------------------------------------------------
-- public entry points
-- ---------------------------------------------------------------------------

local function ensure_root()
	local buf_path = vim.api.nvim_buf_get_name(0)
	if buf_path == "" then
		buf_path = vim.loop.cwd()
	end
	local root = find_root(buf_path)
	if not root then
		notify("no platformio.ini found above " .. buf_path, vim.log.levels.ERROR)
		return nil
	end
	state.root = root
	return root
end

function M.switch(opts)
	opts = opts or {}
	local root = ensure_root()
	if not root then
		return
	end

	local envs = get_envs(root)
	if #envs == 0 then
		notify("no [env:*] sections found", vim.log.levels.WARN)
		return
	end

	-- Explicit env passed via :PioEnv <n>
	if opts.env and opts.env ~= "" then
		local valid = false
		for _, e in ipairs(envs) do
			if e.name == opts.env then
				valid = true
				break
			end
		end
		if not valid then
			notify("unknown env: " .. opts.env, vim.log.levels.ERROR)
			return
		end
		state.target_env = opts.env
		run_compiledb(root, opts.env, function(code)
			if code == 0 then
				restart_clangd()
			end
		end)
		return
	end

	local buf_path = vim.api.nvim_buf_get_name(0)
	local abs = vim.fn.fnamemodify(buf_path, ":p")
	local ranked = rank_envs_for_file(root, abs, envs)

	if config.auto_pick_single and #ranked.matched == 1 then
		local env = ranked.matched[1].name
		notify("single match: " .. env .. " -- regenerating")
		state.target_env = env
		run_compiledb(root, env, function(code)
			if code == 0 then
				restart_clangd()
			end
		end)
		return
	end

	pick_env(ranked, function(env_name)
		state.target_env = env_name
		run_compiledb(root, env_name, function(code)
			if code == 0 then
				restart_clangd()
			end
		end)
	end)
end
-- ---------------------------------------------------------------------------
-- env resolution for build/upload/monitor
--
-- Picks one env to operate on. Precedence:
--   1. Explicit env argument (e.g. `:PioBuild Heltec_v3_repeater`).
--   2. Session target_env (set by :PioEnv or by a previous picker choice).
--   3. Current file ranks exactly one env -> use that.
--   4. Prompt with the env picker; stores the choice as target_env.
-- Callback: on_resolve(root, env_name). Never called if the user cancels.
-- ---------------------------------------------------------------------------

local function find_env_by_name(envs, name)
	for _, e in ipairs(envs) do
		if e.name == name then
			return e
		end
	end
	return nil
end

local function resolve_env(explicit, on_resolve)
	local root = ensure_root()
	if not root then
		return
	end
	local envs = get_envs(root)
	if #envs == 0 then
		notify("no [env:*] sections found", vim.log.levels.WARN)
		return
	end

	if explicit and explicit ~= "" then
		if find_env_by_name(envs, explicit) then
			on_resolve(root, explicit)
		else
			notify("unknown env: " .. explicit, vim.log.levels.ERROR)
		end
		return
	end

	if state.target_env and find_env_by_name(envs, state.target_env) then
		on_resolve(root, state.target_env)
		return
	end

	local buf_path = vim.api.nvim_buf_get_name(0)
	local abs = vim.fn.fnamemodify(buf_path, ":p")
	local ranked = rank_envs_for_file(root, abs, envs)

	if config.auto_pick_single and #ranked.matched == 1 then
		state.target_env = ranked.matched[1].name
		on_resolve(root, state.target_env)
		return
	end

	pick_env(ranked, function(env_name)
		state.target_env = env_name
		on_resolve(root, env_name)
	end)
end

-- ---------------------------------------------------------------------------
-- device (upload port) selection
-- ---------------------------------------------------------------------------

local function parse_device_list(text)
	-- `pio device list` format (one block per port, blank-line separated):
	--   /dev/ttyUSB0
	--   ----------
	--   Hardware ID: USB VID:PID=10C4:EA60 ...
	--   Description: CP2102N USB to UART Bridge Controller
	local devices = {}
	local current = nil
	for line in vim.gsplit(text, "\n", { plain = true }) do
		if line:match("^/") or line:match("^COM%d+") then
			if current then
				table.insert(devices, current)
			end
			current = { port = vim.trim(line), description = "" }
		elseif current then
			local desc = line:match("^Description:%s*(.+)$")
			if desc then
				current.description = vim.trim(desc)
			end
		end
	end
	if current then
		table.insert(devices, current)
	end
	return devices
end

function M.pick_device()
	local root = ensure_root()
	if not root then
		return
	end

	notify("scanning devices...")

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout = vim.loop.new_pipe(false)
	local stderr = vim.loop.new_pipe(false)
	local handle
	handle = vim.loop.spawn(config.pio_cmd, {
		args = { "device", "list" },
		cwd = root,
		stdio = { nil, stdout, stderr },
	}, function(code, _)
		stdout:close()
		stderr:close()
		handle:close()
		vim.schedule(function()
			if code ~= 0 then
				notify(
					"pio device list failed (code " .. code .. "):\n" .. table.concat(stderr_chunks, ""),
					vim.log.levels.ERROR
				)
				return
			end
			local devices = parse_device_list(table.concat(stdout_chunks, ""))
			if #devices == 0 then
				notify("no devices detected", vim.log.levels.WARN)
				return
			end

			local display = {}
			for _, d in ipairs(devices) do
				if d.description ~= "" then
					table.insert(display, d.port .. "  (" .. d.description .. ")")
				else
					table.insert(display, d.port)
				end
			end
			table.insert(display, "── clear selection (use pio default) ──")

			vim.ui.select(display, {
				prompt = "Select upload device:",
				format_item = function(i)
					return i
				end,
			}, function(choice)
				if not choice then
					return
				end
				if choice:match("clear selection") then
					state.device = nil
					notify("device cleared; pio will auto-detect")
					return
				end
				local port = choice:match("^(%S+)")
				state.device = port
				notify("device set: " .. port)
			end)
		end)
	end)

	if not handle then
		notify("failed to spawn pio", vim.log.levels.ERROR)
		return
	end

	stdout:read_start(function(_, data)
		if data then
			table.insert(stdout_chunks, data)
		end
	end)
	stderr:read_start(function(_, data)
		if data then
			table.insert(stderr_chunks, data)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- build / upload
-- ---------------------------------------------------------------------------

function M.build(opts)
	opts = opts or {}
	resolve_env(opts.env, function(root, env_name)
		run_pio({
			root = root,
			args = { "run", "-e", env_name },
			title = "Building [" .. env_name .. "]",
		})
	end)
end

function M.upload(opts)
	opts = opts or {}
	resolve_env(opts.env, function(root, env_name)
		local args = { "run", "-t", "upload", "-e", env_name }
		if state.device then
			table.insert(args, "--upload-port")
			table.insert(args, state.device)
		end
		local title = "Uploading [" .. env_name .. "]"
		if state.device then
			title = title .. " -> " .. state.device
		end
		run_pio({
			root = root,
			args = args,
			title = title,
		})
	end)
end

-- ---------------------------------------------------------------------------
-- monitor (serial terminal in bottom split)
--
-- Opens `pio device monitor` in a bottom split via termopen(). Focus stays
-- in the original window so you can keep editing while watching serial
-- output. Close with `q` in normal mode or :q/:bd from the terminal window;
-- in all cases the child pio process is SIGTERM'd so the serial port gets
-- released (otherwise subsequent uploads fail with "resource busy").
-- ---------------------------------------------------------------------------

function M.monitor(opts)
	opts = opts or {}
	resolve_env(opts.env, function(root, env_name)
		local args = { "device", "monitor", "-e", env_name }
		if state.device then
			table.insert(args, "-p")
			table.insert(args, state.device)
		end

		local origin_win = vim.api.nvim_get_current_win()

		vim.cmd("botright 15split")
		local term_win = vim.api.nvim_get_current_win()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(term_win, buf)
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

		local bufname = "pio-monitor://" .. env_name
		if state.device then
			bufname = bufname .. "@" .. state.device
		end
		pcall(vim.api.nvim_buf_set_name, buf, bufname)

		local cmd = { config.pio_cmd }
		for _, a in ipairs(args) do
			table.insert(cmd, a)
		end

		local job_id
		local function kill_job()
			if job_id and job_id > 0 then
				pcall(vim.fn.jobstop, job_id)
			end
		end

		vim.api.nvim_buf_call(buf, function()
			job_id = vim.fn.termopen(cmd, {
				cwd = root,
				on_exit = function()
					job_id = nil
				end,
			})
		end)

		if not job_id or job_id <= 0 then
			notify("failed to start monitor (is pio installed?)", vim.log.levels.ERROR)
			pcall(vim.api.nvim_win_close, term_win, true)
			return
		end

		vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
			buffer = buf,
			once = true,
			callback = kill_job,
		})

		vim.keymap.set("n", "q", function()
			kill_job()
			if vim.api.nvim_win_is_valid(term_win) then
				vim.api.nvim_win_close(term_win, true)
			end
		end, { buffer = buf, silent = true, nowait = true })

		if vim.api.nvim_win_is_valid(origin_win) then
			vim.api.nvim_set_current_win(origin_win)
		end
	end)
end

function M.status()
	local root = ensure_root()
	if not root then
		return
	end
	local buf_path = vim.api.nvim_buf_get_name(0)
	local envs = get_envs(root)
	local ranked = rank_envs_for_file(root, vim.fn.fnamemodify(buf_path, ":p"), envs)

	local lines = {
		"-- project --",
		"  root:          " .. root,
		"  total envs:    " .. #envs,
		"-- session --",
		"  target env:    " .. (state.target_env or "-"),
		"  device:        " .. (state.device or "- (pio default)"),
		"  last compiled: " .. (state.last_env or "-"),
		"-- current file --",
		"  path:          " .. (buf_path ~= "" and buf_path or "-"),
		"  variant:       " .. (ranked.file_variant or "-"),
		"  arch:          " .. (ranked.file_arch or "-"),
		"  matching envs: " .. #ranked.matched,
	}
	for i, e in ipairs(ranked.matched) do
		if i > 10 then
			table.insert(lines, string.format("    ... and %d more", #ranked.matched - 10))
			break
		end
		table.insert(lines, "    " .. e.name .. " [" .. table.concat(e.archs, ",") .. "]")
	end
	notify(table.concat(lines, "\n"))
end
function M.setup(user_opts)
	config = vim.tbl_deep_extend("force", config, user_opts or {})

	local function env_completer(arglead)
		local root = ensure_root()
		if not root then
			return {}
		end
		local envs = get_envs(root)
		local names = {}
		for _, e in ipairs(envs) do
			if e.name:lower():find(arglead:lower(), 1, true) then
				table.insert(names, e.name)
			end
		end
		return names
	end

	vim.api.nvim_create_user_command("PioEnv", function(cmd)
		M.switch({ env = cmd.args })
	end, {
		nargs = "?",
		desc = "Set target PlatformIO env (regenerates compile_commands.json)",
		complete = env_completer,
	})

	vim.api.nvim_create_user_command("PioStatus", function()
		M.status()
	end, { desc = "Show pio session state and current-file env mapping" })

	vim.api.nvim_create_user_command("PioDevice", function()
		M.pick_device()
	end, { desc = "Select upload device from `pio device list`" })

	vim.api.nvim_create_user_command("PioBuild", function(cmd)
		M.build({ env = cmd.args })
	end, {
		nargs = "?",
		desc = "Build the target env (or resolve from current file)",
		complete = env_completer,
	})

	vim.api.nvim_create_user_command("PioUpload", function(cmd)
		M.upload({ env = cmd.args })
	end, {
		nargs = "?",
		desc = "Upload to the selected device for the target env",
		complete = env_completer,
	})

	vim.api.nvim_create_user_command("PioMonitor", function(cmd)
		M.monitor({ env = cmd.args })
	end, {
		nargs = "?",
		desc = "Open serial monitor in a bottom split",
		complete = env_completer,
	})
end
return M
