--- Difftastic side-by-side diff viewer for Neovim.
local M = {}

local diff = require("difftastic-nvim.diff")
local tree = require("difftastic-nvim.tree")
local highlight = require("difftastic-nvim.highlight")
local keymaps = require("difftastic-nvim.keymaps")

local difftastic_nvim = nil

M.config = {
    download = false, -- Auto-download pre-built binary for your platform
    vcs = "jj",
    keymaps = {
        next_file = "]f",
        prev_file = "[f",
        next_hunk = "]c",
        prev_hunk = "[c",
        close = "q",
        focus_tree = "<Tab>",
        focus_diff = "<Tab>",
        select = "<CR>",
    },
    tree = {
        width = 40,
        icons = {
            enable = true,
            dir_open = "▼",
            dir_closed = "▶",
        },
    },
}

M.state = {
    current_file_idx = 1,
    files = {},
    tree_win = nil,
    tree_buf = nil,
    left_win = nil,
    left_buf = nil,
    right_win = nil,
    right_buf = nil,
    original_buf = nil,
}

local GITHUB_REPO = "clabby/difftastic.nvim"

local function get_platform()
    local os = jit.os:lower()
    local arch = jit.arch:lower()

    if os == "osx" then
        return arch == "arm64" and "aarch64-apple-darwin" or "x86_64-apple-darwin", ".dylib"
    elseif os == "linux" then
        return arch == "arm64" and "aarch64-unknown-linux-gnu" or "x86_64-unknown-linux-gnu", ".so"
    elseif os == "windows" then
        return "x86_64-pc-windows-msvc", ".dll"
    end
    return nil, nil
end

local function get_lib_paths()
    local source = debug.getinfo(1, "S").source:sub(2)
    local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
    local data_dir = vim.fn.stdpath("data") .. "/difftastic-nvim"

    return {
        plugin_root = plugin_root,
        data_dir = data_dir,
        release_dir = plugin_root .. "/target/release",
    }
end

local function try_load_lib(dir, ext)
    local lib_name = ext == ".dylib" and "libdifftastic_nvim.dylib"
        or ext == ".dll" and "difftastic_nvim.dll"
        or "libdifftastic_nvim.so"
    local lib_path = dir .. "/" .. lib_name

    -- Check if library file exists before attempting to load
    if not vim.uv.fs_stat(lib_path) then
        return nil
    end

    if ext == ".dll" then
        -- Windows: Lua can load .dll directly
        package.cpath = dir .. "/?.dll;" .. package.cpath
    else
        -- macOS/Linux: cargo produces lib*.dylib/lib*.so but Lua wants *.so
        local so = dir .. "/difftastic_nvim.so"
        if not vim.uv.fs_stat(so) then
            local ok, err = pcall(vim.uv.fs_symlink, lib_path, so)
            if not ok then
                vim.notify("Failed to create symlink: " .. tostring(err), vim.log.levels.WARN)
            end
        end
        package.cpath = dir .. "/?.so;" .. package.cpath
    end

    local ok, lib = pcall(require, "difftastic_nvim")
    if ok then return lib end
    return nil
end

-- Build state: "ready", "building", "downloading", "failed"
local build_state = "ready"

local function get_lib_name(ext)
    return ext == ".dylib" and "libdifftastic_nvim.dylib"
        or ext == ".dll" and "difftastic_nvim.dll"
        or "libdifftastic_nvim.so"
end

local function lib_exists(paths, ext)
    local lib_name = get_lib_name(ext)
    return vim.uv.fs_stat(paths.data_dir .. "/" .. lib_name)
        or vim.uv.fs_stat(paths.release_dir .. "/" .. lib_name)
end

local function get_version_file(paths)
    return paths.data_dir .. "/.version"
end

local function read_local_version(paths)
    local version_file = get_version_file(paths)
    local f = io.open(version_file, "r")
    if f then
        local version = f:read("*l")
        f:close()
        return version
    end
    return nil
end

local function write_local_version(paths, version)
    local version_file = get_version_file(paths)
    local f = io.open(version_file, "w")
    if f then
        f:write(version)
        f:close()
    end
end

local function check_for_updates(paths)
    local local_version = read_local_version(paths)
    if not local_version then return end

    local releases_url = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases/latest"
    vim.system({ "curl", "-sL", releases_url }, { text = true }, function(result)
        if result.code ~= 0 then return end

        local ok, release = pcall(vim.json.decode, result.stdout)
        if not ok or not release or not release.tag_name then return end

        if release.tag_name ~= local_version then
            vim.schedule(function()
                vim.notify(
                    string.format("difftastic-nvim: Update available (%s -> %s). Run :DifftUpdate", local_version, release.tag_name),
                    vim.log.levels.INFO
                )
            end)
        end
    end)
end

local function download_binary(paths, platform, ext, on_complete)
    build_state = "downloading"
    vim.notify("difftastic-nvim: Downloading binary...", vim.log.levels.INFO)

    vim.fn.mkdir(paths.data_dir, "p")
    local releases_url = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases/latest"

    vim.system({ "curl", "-sL", releases_url }, { text = true }, function(result)
        if result.code ~= 0 then
            vim.schedule(function()
                build_state = "failed"
                vim.notify("difftastic-nvim: Failed to fetch release info", vim.log.levels.ERROR)
                if on_complete then on_complete(false) end
            end)
            return
        end

        local ok, release = pcall(vim.json.decode, result.stdout)
        if not ok or not release or not release.assets then
            vim.schedule(function()
                build_state = "failed"
                vim.notify("difftastic-nvim: No release found", vim.log.levels.ERROR)
                if on_complete then on_complete(false) end
            end)
            return
        end

        local asset_name = platform .. ext
        local download_url = nil
        for _, asset in ipairs(release.assets) do
            if asset.name == asset_name then
                download_url = asset.browser_download_url
                break
            end
        end

        if not download_url then
            vim.schedule(function()
                build_state = "failed"
                vim.notify("difftastic-nvim: No binary for " .. platform, vim.log.levels.ERROR)
                if on_complete then on_complete(false) end
            end)
            return
        end

        local dest_file = paths.data_dir .. "/" .. get_lib_name(ext)
        vim.system({ "curl", "-sL", "-o", dest_file, download_url }, {}, function(dl_result)
            vim.schedule(function()
                if dl_result.code == 0 then
                    write_local_version(paths, release.tag_name)
                    build_state = "ready"
                    vim.notify("difftastic-nvim: Downloaded " .. release.tag_name, vim.log.levels.INFO)
                    if on_complete then on_complete(true) end
                else
                    build_state = "failed"
                    vim.notify("difftastic-nvim: Download failed", vim.log.levels.ERROR)
                    if on_complete then on_complete(false) end
                end
            end)
        end)
    end)
end

local function ensure_lib_exists()
    local platform, ext = get_platform()
    local paths = get_lib_paths()

    -- Already have a binary?
    if lib_exists(paths, ext) then
        build_state = "ready"
        -- Check for updates in background if download is enabled
        if M.config.download then
            check_for_updates(paths)
        end
        return
    end

    -- Try auto-download (async)
    if M.config.download and platform then
        download_binary(paths, platform, ext)
        return
    end

    -- Try building from source (async)
    local cargo_toml = paths.plugin_root .. "/Cargo.toml"
    if vim.uv.fs_stat(cargo_toml) then
        build_state = "building"
        vim.notify("difftastic-nvim: Building from source...", vim.log.levels.INFO)

        vim.system({ "cargo", "build", "--release" }, { cwd = paths.plugin_root, text = true }, function(result)
            vim.schedule(function()
                if result.code == 0 then
                    build_state = "ready"
                    vim.notify("difftastic-nvim: Build complete", vim.log.levels.INFO)
                else
                    build_state = "failed"
                    vim.notify("difftastic-nvim: Build failed: " .. (result.stderr or "unknown error"), vim.log.levels.ERROR)
                end
            end)
        end)
        return
    end

    -- No way to get the library
    build_state = "failed"
    local lib_name = get_lib_name(ext)
    vim.notify(string.format(
        "difftastic-nvim: Could not find %s.\nSet download = true, or install Rust toolchain.",
        lib_name
    ), vim.log.levels.ERROR)
end

local function get_rust_lib()
    if difftastic_nvim then return difftastic_nvim end

    if build_state == "building" then
        error("difftastic-nvim: Still building, please wait...")
    elseif build_state == "downloading" then
        error("difftastic-nvim: Still downloading, please wait...")
    elseif build_state == "failed" then
        error("difftastic-nvim: Library not available. Check :messages for details.")
    end

    local _, ext = get_platform()
    local paths = get_lib_paths()

    local lib = try_load_lib(paths.data_dir, ext)
        or try_load_lib(paths.release_dir, ext)

    if lib then
        difftastic_nvim = lib
        return difftastic_nvim
    end

    error("difftastic-nvim: Library not found.")
end

function M.setup(opts)
    opts = opts or {}
    if opts.download ~= nil then
        M.config.download = opts.download
    end
    M.config.vcs = opts.vcs or M.config.vcs
    if opts.keymaps then
        M.config.keymaps = vim.tbl_extend("force", M.config.keymaps, opts.keymaps)
    end
    if opts.tree then
        if opts.tree.icons then
            M.config.tree.icons = vim.tbl_extend("force", M.config.tree.icons, opts.tree.icons)
        end
        if opts.tree.width then
            M.config.tree.width = opts.tree.width
        end
    end
    highlight.setup(opts.highlights)
    ensure_lib_exists()
end

function M.open(revset)
    if M.state.tree_win or M.state.left_win or M.state.right_win then
        M.close()
    end

    local result = get_rust_lib().run_diff(revset, M.config.vcs)
    if not result.files or #result.files == 0 then
        vim.notify("No changes found", vim.log.levels.INFO)
        return
    end

    M.state.files = result.files
    M.state.current_file_idx = 1

    local original_win = vim.api.nvim_get_current_win()
    M.state.original_buf = vim.api.nvim_get_current_buf()

    tree.open(M.state)
    diff.open(M.state)
    keymaps.setup(M.state)

    if vim.api.nvim_win_is_valid(original_win)
        and original_win ~= M.state.tree_win
        and original_win ~= M.state.left_win
        and original_win ~= M.state.right_win
    then
        vim.api.nvim_win_close(original_win, false)
    end

    local first_idx = tree.first_file_in_display_order()
    if first_idx then M.show_file(first_idx) end
end

function M.close()
    local wins = {}
    for _, win in ipairs({ M.state.tree_win, M.state.left_win, M.state.right_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            table.insert(wins, win)
        end
    end

    if #wins == 0 then return end

    for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            if #vim.api.nvim_list_wins() > 1 then
                vim.api.nvim_win_close(win, true)
            else
                vim.api.nvim_set_current_win(win)
                if M.state.original_buf and vim.api.nvim_buf_is_valid(M.state.original_buf) then
                    vim.api.nvim_win_set_buf(win, M.state.original_buf)
                else
                    vim.cmd("enew")
                end
            end
        end
    end

    M.state = {
        current_file_idx = 1,
        files = {},
        tree_win = nil,
        tree_buf = nil,
        left_win = nil,
        left_buf = nil,
        right_win = nil,
        right_buf = nil,
        original_buf = nil,
    }
end

function M.show_file(idx)
    if idx < 1 or idx > #M.state.files then return end
    M.state.current_file_idx = idx
    diff.render(M.state, M.state.files[idx])
    tree.highlight_current(M.state)
end

function M.next_file()
    local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
    if next_idx then M.show_file(next_idx) end
end

function M.prev_file()
    local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
    if prev_idx then M.show_file(prev_idx) end
end

function M.next_hunk() diff.next_hunk(M.state) end
function M.prev_hunk() diff.prev_hunk(M.state) end

function M.update()
    local platform, ext = get_platform()
    if not platform then
        vim.notify("difftastic-nvim: Unsupported platform", vim.log.levels.ERROR)
        return
    end

    local paths = get_lib_paths()

    -- Remove old binary and symlink to force re-download
    local lib_path = paths.data_dir .. "/" .. get_lib_name(ext)
    local so_path = paths.data_dir .. "/difftastic_nvim.so"
    vim.uv.fs_unlink(lib_path)
    vim.uv.fs_unlink(so_path)

    -- Clear cached library so it reloads
    package.loaded["difftastic_nvim"] = nil
    difftastic_nvim = nil

    download_binary(paths, platform, ext)
end

return M
