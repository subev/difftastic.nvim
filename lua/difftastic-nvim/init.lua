--- Difftastic side-by-side diff viewer for Neovim.
local M = {}

local binary = require("difftastic-nvim.binary")
local diff = require("difftastic-nvim.diff")
local tree = require("difftastic-nvim.tree")
local highlight = require("difftastic-nvim.highlight")
local keymaps = require("difftastic-nvim.keymaps")
local watcher = require("difftastic-nvim.watcher")

--- Default configuration
M.config = {
    download = false,
    vcs = "git",
    --- Highlight mode: "treesitter" (full syntax) or "difftastic" (no syntax, colored changes only)
    highlight_mode = "treesitter",
    --- When true, next_hunk at last hunk wraps to next file (and prev_hunk to prev file)
    hunk_wrap_file = false,
    --- Watch .git/index for changes and auto-refresh
    watch_index = true,
    --- Refresh on BufWritePost for files in the current diff
    refresh_on_save = true,
    --- Automatically scroll to first hunk when opening a file
    auto_scroll_first_hunk = true,
    keymaps = {
        next_file = "]f",
        prev_file = "[f",
        next_hunk = "]c",
        prev_hunk = "[c",
        close = "q",
        focus_tree = "<Tab>",
        focus_diff = "<Tab>",
        select = "<CR>",
        goto_file = "gf",
    },
    tree = {
        width = 40,
        icons = {
            enable = true,
            dir_open = "",
            dir_closed = "",
        },
    },
}

--- Current diff state
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
    --- Tabpage where difftastic is open
    tabpage = nil,
    --- The revset/range used to open the diff (nil = unstaged, "--staged" = staged)
    revset = nil,
    --- Hash of current files for change detection
    files_hash = nil,
    --- Autocmd ID for BufWritePost
    bufwrite_autocmd = nil,
}

--- Compute a hash of the current file list for change detection.
--- Uses file paths and their stats (additions/deletions) to detect changes.
--- @param files table[] List of file objects
--- @return string hash
local function compute_files_hash(files)
    local parts = {}
    for _, file in ipairs(files) do
        table.insert(parts, string.format(
            "%s:%s:%d:%d",
            file.path or "",
            file.status or "",
            file.additions or 0,
            file.deletions or 0
        ))
    end
    return table.concat(parts, "|")
end

--- Check if a path matches any file in the current diff.
--- @param path string File path to check
--- @return boolean
local function is_file_in_diff(path)
    -- Normalize the path (remove leading ./ if present)
    local normalized = path:gsub("^%./", "")

    for _, file in ipairs(M.state.files) do
        local file_path = (file.path or ""):gsub("^%./", "")
        if file_path == normalized then
            return true
        end
    end
    return false
end

--- Fetch diff data from the Rust binary.
--- @param revset string|nil
--- @return table|nil result
local function fetch_diff(revset)
    local result
    if revset == nil then
        result = binary.get().run_diff_unstaged(M.config.vcs)
    elseif revset == "--staged" then
        result = binary.get().run_diff_staged(M.config.vcs)
    else
        result = binary.get().run_diff(revset, M.config.vcs)
    end
    return result
end

--- Initialize the plugin with user options.
--- @param opts table|nil User configuration
function M.setup(opts)
    opts = opts or {}

    -- Merge config
    if opts.download ~= nil then
        M.config.download = opts.download
    end
    if opts.vcs then
        M.config.vcs = opts.vcs
    end
    if opts.highlight_mode then
        M.config.highlight_mode = opts.highlight_mode
    end
    if opts.hunk_wrap_file ~= nil then
        M.config.hunk_wrap_file = opts.hunk_wrap_file
    end
    if opts.watch_index ~= nil then
        M.config.watch_index = opts.watch_index
    end
    if opts.refresh_on_save ~= nil then
        M.config.refresh_on_save = opts.refresh_on_save
    end
    if opts.auto_scroll_first_hunk ~= nil then
        M.config.auto_scroll_first_hunk = opts.auto_scroll_first_hunk
    end
    if opts.keymaps then
        -- Manual merge to preserve explicit false/nil values (tbl_extend ignores nil)
        for k, v in pairs(opts.keymaps) do
            M.config.keymaps[k] = v
        end
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
    binary.ensure_exists(M.config.download)
end

--- Reset state to initial values.
local function reset_state()
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
        tabpage = nil,
        revset = nil,
        files_hash = nil,
        bufwrite_autocmd = nil,
    }
end

--- Start file watchers and autocmds.
local function start_watchers()
    -- Start .git/index watcher
    if M.config.watch_index and M.config.vcs == "git" then
        watcher.start(function()
            -- Only refresh if we're on the difftastic tab
            if M.state.tabpage and vim.api.nvim_get_current_tabpage() == M.state.tabpage then
                M.refresh()
            end
        end)
    end

    -- Set up BufWritePost autocmd
    if M.config.refresh_on_save then
        M.state.bufwrite_autocmd = vim.api.nvim_create_autocmd("BufWritePost", {
            callback = function(args)
                -- Only if difftastic is open
                if not M.state.tabpage then
                    return
                end

                -- Get relative path of saved file
                local saved_path = vim.fn.fnamemodify(args.file, ":.")

                -- Only refresh if saved file is in our diff
                if is_file_in_diff(saved_path) then
                    M.refresh()
                end
            end,
        })
    end
end

--- Stop file watchers and autocmds.
local function stop_watchers()
    watcher.stop()

    if M.state.bufwrite_autocmd then
        vim.api.nvim_del_autocmd(M.state.bufwrite_autocmd)
        M.state.bufwrite_autocmd = nil
    end
end

--- Open diff view for a revision/commit range.
--- Creates a new tab or reuses existing difftastic tab.
--- @param revset string|nil jj revset or git commit range (nil = unstaged, "--staged" = staged)
function M.open(revset)
    -- If already open in a tab, switch to it and refresh
    if M.state.tabpage and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
        vim.api.nvim_set_current_tabpage(M.state.tabpage)
        M.state.revset = revset
        M.refresh()
        return
    end

    -- Fetch diff data first to check if there are changes
    local result = fetch_diff(revset)
    if not result or not result.files or #result.files == 0 then
        vim.notify("No changes found", vim.log.levels.INFO)
        return
    end

    -- Store state before creating new tab
    M.state.original_buf = vim.api.nvim_get_current_buf()
    M.state.revset = revset

    -- Create a new tab for difftastic
    vim.cmd("tabnew")
    M.state.tabpage = vim.api.nvim_get_current_tabpage()

    -- Remember the initial empty window so we can close it later
    local initial_win = vim.api.nvim_get_current_win()

    -- Set up the view
    M.state.files = result.files
    M.state.files_hash = compute_files_hash(result.files)
    M.state.current_file_idx = 1

    tree.open(M.state)
    diff.open(M.state)
    keymaps.setup(M.state)

    -- Close the initial empty window created by tabnew
    if vim.api.nvim_win_is_valid(initial_win) then
        vim.api.nvim_win_close(initial_win, true)
    end

    -- Start watchers after view is set up
    start_watchers()

    -- Show first file
    local first_idx = tree.first_file_in_display_order()
    if first_idx then
        M.show_file(first_idx)
    end

    -- Focus the right (new) pane
    if M.state.right_win and vim.api.nvim_win_is_valid(M.state.right_win) then
        vim.api.nvim_set_current_win(M.state.right_win)
    end
end

--- Refresh the diff view with updated data.
--- Preserves current file selection if possible.
function M.refresh()
    -- Only refresh if difftastic is open
    if not M.state.tabpage or not vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
        return
    end

    -- Fetch new diff data
    local result = fetch_diff(M.state.revset)

    -- Handle case where there are no more changes
    if not result or not result.files or #result.files == 0 then
        vim.notify("No changes found", vim.log.levels.INFO)
        M.close()
        return
    end

    -- Check if files actually changed
    local new_hash = compute_files_hash(result.files)
    if new_hash == M.state.files_hash then
        return -- No changes, skip re-render
    end

    -- Find current file path to preserve selection
    local current_path = nil
    if M.state.files[M.state.current_file_idx] then
        current_path = M.state.files[M.state.current_file_idx].path
    end

    -- Update state
    M.state.files = result.files
    M.state.files_hash = new_hash

    -- Find the same file in the new list (by path)
    local new_idx = 1
    if current_path then
        for i, file in ipairs(result.files) do
            if file.path == current_path then
                new_idx = i
                break
            end
        end
    end
    M.state.current_file_idx = new_idx

    -- Rebuild tree and re-render
    tree.rebuild(M.state)
    M.show_file(new_idx)
end

--- Close the diff view.
function M.close()
    -- Stop watchers first
    stop_watchers()

    -- Close the tab if it exists and is valid
    if M.state.tabpage and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
        -- Get all tabs to check if this is the only one
        local tabs = vim.api.nvim_list_tabpages()

        if #tabs > 1 then
            -- Switch to another tab first, then close this one
            local current_tab = vim.api.nvim_get_current_tabpage()
            if current_tab == M.state.tabpage then
                -- Find another tab to switch to
                for _, tab in ipairs(tabs) do
                    if tab ~= M.state.tabpage then
                        vim.api.nvim_set_current_tabpage(tab)
                        break
                    end
                end
            end

            -- Close all windows in the difftastic tab
            local wins = vim.api.nvim_tabpage_list_wins(M.state.tabpage)
            for _, win in ipairs(wins) do
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
            end
        else
            -- Only one tab - close windows and create new buffer
            local wins = { M.state.tree_win, M.state.left_win, M.state.right_win }
            for _, win in ipairs(wins) do
                if win and vim.api.nvim_win_is_valid(win) then
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
        end
    end

    -- Explicitly delete buffers to avoid name conflicts on reopen
    for _, buf in ipairs({ M.state.tree_buf, M.state.left_buf, M.state.right_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    reset_state()
end

--- Show a specific file by index.
--- @param idx number File index (1-based)
function M.show_file(idx)
    if idx < 1 or idx > #M.state.files then
        return
    end
    M.state.current_file_idx = idx
    diff.render(M.state, M.state.files[idx])
    tree.highlight_current(M.state)
end

--- Navigate to the next file.
function M.next_file()
    local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
    if next_idx then
        M.show_file(next_idx)
    end
end

--- Navigate to the previous file.
function M.prev_file()
    local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
    if prev_idx then
        M.show_file(prev_idx)
    end
end

--- Navigate to the next hunk.
--- If hunk_wrap_file is enabled and at the last hunk, wraps to the first hunk of the next file.
function M.next_hunk()
    local jumped = diff.next_hunk(M.state)
    if not jumped and M.config.hunk_wrap_file then
        local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
        if next_idx then
            M.show_file(next_idx)
            vim.defer_fn(function()
                diff.first_hunk(M.state)
            end, 10)
        else
            -- At last file, wrap to first file
            local first_idx = tree.first_file_in_display_order()
            if first_idx then
                M.show_file(first_idx)
                vim.defer_fn(function()
                    diff.first_hunk(M.state)
                end, 10)
            end
        end
    end
end

--- Navigate to the previous hunk.
--- If hunk_wrap_file is enabled and at the first hunk, wraps to the last hunk of the previous file.
function M.prev_hunk()
    local jumped = diff.prev_hunk(M.state)
    if not jumped and M.config.hunk_wrap_file then
        local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
        if prev_idx then
            M.show_file(prev_idx)
            vim.defer_fn(function()
                diff.last_hunk(M.state)
            end, 10)
        else
            -- At first file, wrap to last file
            local last_idx = tree.last_file_in_display_order()
            if last_idx then
                M.show_file(last_idx)
                vim.defer_fn(function()
                    diff.last_hunk(M.state)
                end, 10)
            end
        end
    end
end

--- Go to the file at the current cursor position in an editable buffer.
--- Opens in a previous tabpage if one exists, otherwise creates a new tab.
--- Only works from the right pane (new/working version of the file).
function M.goto_file()
    local state = M.state
    local current_win = vim.api.nvim_get_current_win()

    -- Only works from right pane (new version)
    if current_win ~= state.right_win then
        return
    end

    local file = state.files[state.current_file_idx]
    if not file then
        return
    end

    -- Deleted files have no right-side content to navigate to
    if file.status == "deleted" then
        return
    end

    -- Get current cursor position (row is 1-indexed, col is 0-indexed)
    local cursor = vim.api.nvim_win_get_cursor(current_win)
    local row, col = cursor[1], cursor[2]
    local aligned = file.aligned_lines and file.aligned_lines[row]

    -- Find the target line number (right side = new version)
    local target_line
    if aligned and aligned[2] then
        -- Direct mapping exists
        target_line = aligned[2] + 1 -- 0-indexed to 1-indexed
    else
        -- Filler line - find nearest non-filler line
        -- Search upward first, then downward
        for offset = 1, #file.aligned_lines do
            -- Check above
            if row - offset >= 1 then
                local above = file.aligned_lines[row - offset]
                if above and above[2] then
                    target_line = above[2] + 1
                    break
                end
            end
            -- Check below
            if row + offset <= #file.aligned_lines then
                local below = file.aligned_lines[row + offset]
                if below and below[2] then
                    target_line = below[2] + 1
                    break
                end
            end
        end
    end

    -- Fallback to line 1 if no mapping found
    target_line = target_line or 1

    local filepath = file.path

    -- Find previous tabpage or create new one
    local current_tab = vim.api.nvim_get_current_tabpage()
    local tabs = vim.api.nvim_list_tabpages()
    local target_tab = nil

    for i, tab in ipairs(tabs) do
        if tab == current_tab and i > 1 then
            target_tab = tabs[i - 1]
            break
        end
    end

    if target_tab then
        vim.api.nvim_set_current_tabpage(target_tab)
    else
        vim.cmd("tabnew")
    end

    -- Open file and jump to line and column
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    -- Clamp column to line length to avoid errors on shorter lines
    local line_content = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1] or ""
    local target_col = math.min(col, math.max(0, #line_content - 1))
    vim.api.nvim_win_set_cursor(0, { target_line, target_col })
end

--- Update binary to latest release.
function M.update()
    binary.update()
end

return M
