--- Commit history tree sidebar using nui.nvim.
local M = {}

local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

--- Safely set buffer name, deleting any existing buffer with the same name.
--- @param buf number Buffer handle
--- @param name string Buffer name
local function safe_buf_set_name(buf, name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and existing ~= buf then
        pcall(vim.api.nvim_buf_delete, existing, { force = true })
    end
    vim.api.nvim_buf_set_name(buf, name)
end

--- Module state
--- @type table|nil
M.tree = nil
--- @type number|nil
M.current_commit_idx = nil
--- Number of header lines (blank + filename + commit count + blank)
M.header_lines = 4

--- @return table Tree configuration
local function get_config()
    return require("difftastic-nvim").config.tree
end

--- Convert commits to NuiTree nodes.
--- @param commits table[] List of commit objects
--- @return table[] NuiTree nodes
local function convert_to_nui_nodes(commits)
    local nodes = {}

    for idx, commit in ipairs(commits) do
        local node = NuiTree.Node({
            id = commit.hash,
            commit_idx = idx,
            hash = commit.hash,
            short_hash = commit.short_hash,
            author = commit.author,
            relative_date = commit.relative_date,
            message = commit.message,
        })
        table.insert(nodes, node)
    end

    return nodes
end

--- Prepare a node for rendering.
--- @param node table NuiTree node
--- @return table NuiLine
local function prepare_node(node)
    local line = NuiLine()

    -- Indentation
    line:append("  ")

    -- Date
    line:append(node.relative_date, "DifftHistoryDate")

    line:append("  ")

    -- Author
    line:append(node.author, "DifftHistoryAuthor")

    line:append("  ")

    -- Message
    line:append(node.message, "DifftHistoryMessage")

    return line
end

--- Render the header with file info.
--- @param state table History state
local function render_header(state)
    local width = get_config().width
    local filename = vim.fn.fnamemodify(state.file_path, ":t")
    local commit_count = #state.commits

    -- Line 1: blank
    -- Line 2: "History: <filename>"
    -- Line 3: "<N> commits"
    -- Line 4: blank

    local header_line = "History: " .. filename
    local count_line = commit_count .. " commit" .. (commit_count == 1 and "" or "s")

    -- Center the lines
    local header_padding = math.floor((width - #header_line) / 2)
    local count_padding = math.floor((width - #count_line) / 2)

    local padded_header = string.rep(" ", math.max(0, header_padding)) .. header_line
    local padded_count = string.rep(" ", math.max(0, count_padding)) .. count_line

    vim.api.nvim_buf_set_lines(state.tree_buf, 0, 0, false, { "", padded_header, padded_count, "" })

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace("difft-history-header")
    vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftHistoryHeader", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftHistoryCount", 2, 0, -1)
end

--- Open the history tree sidebar.
--- @param state table History state with commits and file_path
function M.open(state)
    vim.cmd("topleft vertical " .. get_config().width .. " new")
    state.tree_win = vim.api.nvim_get_current_win()
    state.tree_buf = vim.api.nvim_get_current_buf()

    vim.wo[state.tree_win].number = false
    vim.wo[state.tree_win].relativenumber = false
    vim.wo[state.tree_win].signcolumn = "no"
    vim.wo[state.tree_win].winfixwidth = true
    vim.wo[state.tree_win].cursorline = true
    vim.wo[state.tree_win].scrollbind = false
    vim.wo[state.tree_win].cursorbind = false
    vim.wo[state.tree_win].wrap = false

    safe_buf_set_name(state.tree_buf, "difftastic://history")
    vim.bo[state.tree_buf].buftype = "nofile"
    vim.bo[state.tree_buf].bufhidden = "wipe"
    vim.bo[state.tree_buf].swapfile = false
    vim.bo[state.tree_buf].filetype = "difft-history-tree"
    vim.bo[state.tree_buf].modifiable = true

    -- Render header first
    render_header(state)

    -- Convert commits to nui nodes
    local nui_nodes = convert_to_nui_nodes(state.commits)

    -- Create nui tree (starts after header)
    M.tree = NuiTree({
        bufnr = state.tree_buf,
        nodes = nui_nodes,
        prepare_node = prepare_node,
    })

    M.tree:render(M.header_lines + 1)

    -- Set up keymaps
    local history = require("difftastic-nvim.history")
    local difft = require("difftastic-nvim")
    local keys = difft.config.keymaps

    vim.keymap.set("n", keys.select, function()
        local node = M.tree:get_node()
        if not node then return end

        if node.commit_idx then
            history.show_commit(node.commit_idx)
        end
    end, { buffer = state.tree_buf })

    vim.keymap.set("n", keys.close, history.close, { buffer = state.tree_buf })
end

--- Get the next commit index in display order.
--- @param current_idx number Current commit index
--- @return number|nil Next commit index or nil if at end
function M.next_commit(current_idx)
    if not M.tree then return nil end
    local nodes = M.tree:get_nodes()
    for i, node in ipairs(nodes) do
        if node.commit_idx == current_idx and nodes[i + 1] then
            return nodes[i + 1].commit_idx
        end
    end
    return nil
end

--- Get the previous commit index in display order.
--- @param current_idx number Current commit index
--- @return number|nil Previous commit index or nil if at start
function M.prev_commit(current_idx)
    if not M.tree then return nil end
    local nodes = M.tree:get_nodes()
    for i, node in ipairs(nodes) do
        if node.commit_idx == current_idx and i > 1 then
            return nodes[i - 1].commit_idx
        end
    end
    return nil
end

--- Get the first commit index.
--- @return number|nil
function M.first_commit()
    if not M.tree then return nil end
    local nodes = M.tree:get_nodes()
    if nodes[1] then
        return nodes[1].commit_idx
    end
    return nil
end

--- Get the last commit index.
--- @return number|nil
function M.last_commit()
    if not M.tree then return nil end
    local nodes = M.tree:get_nodes()
    if #nodes > 0 then
        return nodes[#nodes].commit_idx
    end
    return nil
end

--- Highlight the currently selected commit.
--- @param state table History state
function M.highlight_current(state)
    if not M.tree or not state.tree_buf then return end

    local ns = vim.api.nvim_create_namespace("difft-history-current")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, M.header_lines, -1)

    M.current_commit_idx = state.current_commit_idx

    -- Find the line number by iterating through rendered lines (after header)
    local line_count = vim.api.nvim_buf_line_count(state.tree_buf)
    for linenr = M.header_lines + 1, line_count do
        local node = M.tree:get_node(linenr)
        if node and node.commit_idx == state.current_commit_idx then
            vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeCurrent", linenr - 1, 0, -1)
            if vim.api.nvim_win_is_valid(state.tree_win) then
                vim.api.nvim_win_set_cursor(state.tree_win, { linenr, 0 })
            end
            break
        end
    end
end

return M
