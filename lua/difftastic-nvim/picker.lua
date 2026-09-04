--- Optional Snacks picker integration for selecting revisions/commits.
local M = {}
local PREVIEW_NS = vim.api.nvim_create_namespace("difftastic-nvim-picker-preview")
local PREVIEW_HL = "DifftPickerPreviewHover"
local PREVIEW_SIGN_GROUP = "difftastic_picker_preview"
local PREVIEW_SIGN_NAME = "DifftPickerPreviewLine"

pcall(vim.fn.sign_define, PREVIEW_SIGN_NAME, { text = "", texthl = PREVIEW_HL, linehl = PREVIEW_HL, numhl = PREVIEW_HL })

local function is_set(value)
    return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function run_command(cmd)
    local lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
        return nil
    end
    return lines
end

local function display_width(s)
    return vim.fn.strdisplaywidth(s)
end

local function pad_right(s, width)
    local pad = width - display_width(s)
    if pad <= 0 then
        return s
    end
    return s .. string.rep(" ", pad)
end

local function pad_left(s, width)
    local pad = width - display_width(s)
    if pad <= 0 then
        return s
    end
    return string.rep(" ", pad) .. s
end

local function fit_description(desc)
    desc = desc ~= "" and desc or "(no description set)"
    if vim.fn.strchars(desc) > 40 then
        return vim.fn.strcharpart(desc, 0, 40) .. "..."
    end
    return pad_right(desc, 43)
end

local function strip_ansi(s)
    return (s:gsub("\27%[[0-9;]*m", ""))
end

local function is_commit_header_line(line)
    local clean = strip_ansi(line)
    return clean:match("%x%x%x%x%x%x%x%x%s*$") ~= nil
end

local function apply_preview_hover_highlight(buf, win, lines, rev)
    if not (rev and vim.api.nvim_buf_is_valid(buf)) then
        return
    end

    local short = rev:sub(1, 8)
    local row
    for i, line in ipairs(lines) do
        if strip_ansi(line):find(short, 1, true) then
            row = i
            break
        end
    end
    if not row then
        return
    end

    local function overlay_line(line_nr)
        local text = strip_ansi(lines[line_nr] or "")
        local end_col = math.max(vim.fn.strdisplaywidth(text), 1)
        vim.api.nvim_buf_set_extmark(buf, PREVIEW_NS, line_nr - 1, 0, {
            end_row = line_nr - 1,
            end_col = end_col,
            hl_group = PREVIEW_HL,
            hl_eol = true,
            priority = 4096,
        })
    end

    local function clear_window_matches()
        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        vim.api.nvim_win_call(win, function()
            local ids = vim.w.difftastic_picker_preview_match_ids
            if type(ids) == "table" then
                for _, id in ipairs(ids) do
                    pcall(vim.fn.matchdelete, id)
                end
            end
            vim.w.difftastic_picker_preview_match_ids = {}
        end)
    end

    local function overlay_window_lines(line_numbers)
        if not vim.api.nvim_win_is_valid(win) then
            return
        end
        vim.api.nvim_win_call(win, function()
            local ids = {}
            for _, line_nr in ipairs(line_numbers) do
                local id = vim.fn.matchaddpos(PREVIEW_HL, { { line_nr } }, 99)
                if id and id > 0 then
                    table.insert(ids, id)
                end
            end
            vim.w.difftastic_picker_preview_match_ids = ids
        end)
    end

    local function overlay_sign_lines(line_numbers)
        pcall(vim.fn.sign_unplace, PREVIEW_SIGN_GROUP, { buffer = buf })
        for _, line_nr in ipairs(line_numbers) do
            pcall(vim.fn.sign_place, 0, PREVIEW_SIGN_GROUP, PREVIEW_SIGN_NAME, buf, {
                lnum = line_nr,
                priority = 99,
            })
        end
    end

    vim.api.nvim_buf_clear_namespace(buf, PREVIEW_NS, 0, -1)
    clear_window_matches()

    local hovered_lines = { row }
    overlay_line(row)

    local next_line = lines[row + 1]
    if next_line and next_line ~= "" and not strip_ansi(next_line):match("^~+$") and not is_commit_header_line(next_line) then
        overlay_line(row + 1)
        table.insert(hovered_lines, row + 1)
    end

    overlay_window_lines(hovered_lines)
    overlay_sign_lines(hovered_lines)

    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { row, 0 })
        vim.api.nvim_win_call(win, function()
            vim.cmd("normal! zz")
        end)
    end
end

-- test-only hook
M._apply_preview_hover_highlight = apply_preview_hover_highlight

local function compact_age(ts)
    local secs = math.max(os.time() - ts, 0)
    local mins = math.floor(secs / 60)
    if mins < 1 then
        return "now"
    end
    if mins < 60 then
        return mins .. "m"
    end
    local hours = math.floor(mins / 60)
    if hours < 24 then
        return hours .. "h"
    end
    local days = math.floor(hours / 24)
    if days < 14 then
        return days .. "d"
    end
    if days < 60 then
        return math.floor(days / 7) .. "w"
    end
    if days < 365 then
        return math.floor(days / 30.44) .. "mo"
    end
    return math.floor(days / 365) .. "y"
end

local function parse_shortstat(line)
    return {
        files = tonumber(line:match("(%d+) files? changed")) or 0,
        ins = tonumber(line:match("(%d+) insertions?%(%+%)")) or 0,
        del = tonumber(line:match("(%d+) deletions?%(%-%)")) or 0,
    }
end

local function staged_stat()
    local lines = run_command({ "git", "diff", "--cached", "--shortstat" })
    if not lines then
        return nil
    end
    for _, line in ipairs(lines) do
        if line:match("files? changed") then
            return parse_shortstat(line)
        end
    end
    return nil
end

local function git_items(limit, revspec, exclude_rev, include_staged)
    local cmd = {
        "git",
        "log",
        -- \30 marks commit headers so --shortstat lines attribute to the right commit
        "--pretty=format:\30%H\t%h\t%at\t%s",
        "--shortstat",
        "--diff-merges=first-parent",
        "-n",
        tostring(limit),
    }
    if is_set(revspec) then
        table.insert(cmd, revspec)
    end

    local lines = run_command(cmd)
    if not lines then
        return nil
    end

    local raw_items = {}
    local current
    for _, line in ipairs(lines) do
        local full, short, ts, subject = line:match("^\30([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
        if full then
            current = nil
            if full ~= exclude_rev then
                current = {
                    rev = full,
                    short = short,
                    age = compact_age(tonumber(ts) or os.time()),
                    subject = subject or "",
                    match_text = short .. " " .. (subject or ""),
                }
                table.insert(raw_items, current)
            end
        elseif current and line:match("files? changed") then
            current.stat = parse_shortstat(line)
        end
    end

    local staged = include_staged and staged_stat() or nil
    if staged then
        table.insert(
            raw_items,
            1,
            {
                rev = "--staged",
                short = "(STAGED)",
                age = "",
                stat = staged,
                subject = "staged changes",
                match_text = "(STAGED) staged changes",
            }
        )
    end

    local w = { short = 0, age = 0, files = 0, ins = 0, del = 0 }
    for _, item in ipairs(raw_items) do
        if item.stat then
            item.files = item.stat.files .. "f"
            item.ins = "+" .. item.stat.ins
            item.del = "-" .. item.stat.del
        end
        w.short = math.max(w.short, display_width(item.short))
        w.age = math.max(w.age, display_width(item.age))
        w.files = math.max(w.files, display_width(item.files or ""))
        w.ins = math.max(w.ins, display_width(item.ins or ""))
        w.del = math.max(w.del, display_width(item.del or ""))
    end

    local items = {}
    for _, item in ipairs(raw_items) do
        table.insert(items, {
            rev = item.rev,
            match_text = item.match_text,
            text = string.format(
                "%s %s %s %s %s  %s",
                pad_right(item.short, w.short),
                pad_left(item.age, w.age),
                pad_left(item.files or "", w.files),
                pad_left(item.ins or "", w.ins),
                pad_left(item.del or "", w.del),
                item.subject
            ),
        })
    end
    return items
end

local function jj_items(limit, revset, exclude_rev)
    local cmd = { "jj", "log", "--no-graph", "-n", tostring(limit) }

    if is_set(revset) then
        table.insert(cmd, "-r")
        table.insert(cmd, revset)
    end

    table.insert(cmd, "-T")
    table.insert(
        cmd,
        'if(current_working_copy, "@", if(immutable, "◆", "○")) ++ "\\t" ++ description.first_line() ++ "\\t" ++ change_id.shortest() ++ "\\t" ++ author.timestamp().ago() ++ "\\t" ++ commit_id ++ "\\n"'
    )

    local lines = run_command(cmd)
    if not lines then
        return nil
    end

    local raw_items = {}
    local revset_w = 0
    for _, line in ipairs(lines) do
        local icon, desc, revset_id, age, rev = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]+)$")
        if rev and rev ~= exclude_rev then
            revset_w = math.max(revset_w, display_width(revset_id))
            table.insert(raw_items, {
                icon = icon,
                desc = desc,
                revset_id = revset_id,
                age = age,
                rev = rev,
            })
        end
    end

    local items = {}
    for _, item in ipairs(raw_items) do
        local icon_hl = "DifftPickerJjIconNormal"
        if item.icon == "@" then
            icon_hl = "DifftPickerJjIconCurrent"
        elseif item.icon == "◆" then
            icon_hl = "DifftPickerJjIconImmutable"
        end

        local desc = fit_description(item.desc)
        local revset = pad_right(item.revset_id, revset_w)
        local text = string.format(
            "%s %s %s %s",
            item.icon,
            desc,
            revset,
            item.age
        )
        table.insert(items, {
            rev = item.rev,
            match_text = item.revset_id .. " " .. item.desc,
            text = text,
            chunks = {
                { item.icon .. " ", icon_hl },
                { desc, "DifftPickerJjDesc" },
                { " " .. revset, "DifftPickerJjRevset" },
                { " " .. item.age, "DifftPickerJjAge" },
            },
        })
    end

    return items
end

local function jj_preview(opts)
    return function(ctx)
        local preview = require("snacks.picker.preview")
        local cmd = { "jj", "log", "--color=always", "-n", tostring(opts.limit) }
        if is_set(opts.jj_log_revset) then
            table.insert(cmd, "-r")
            table.insert(cmd, opts.jj_log_revset)
        end

        preview.cmd(cmd, ctx, {
            term = true,
            ansi = false,
            pty = true,
            on_exit = function()
                local preview_win = ctx.preview and ctx.preview.win and ctx.preview.win.win or ctx.win
                local preview_buf = ctx.preview and ctx.preview.win and ctx.preview.win.buf or ctx.buf
                if not (ctx.item and ctx.item.rev and vim.api.nvim_buf_is_valid(preview_buf)) then
                    return
                end

                local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
                apply_preview_hover_highlight(preview_buf, preview_win, lines, ctx.item.rev)
            end,
        })
    end
end

local function effective_jj_revset(opts, rev_filter)
    if is_set(rev_filter) and is_set(opts.jj_log_revset) then
        return string.format("(%s) & (%s)", rev_filter, opts.jj_log_revset)
    end
    if is_set(rev_filter) then
        return rev_filter
    end
    return opts.jj_log_revset
end

local function load_items(vcs, opts, rev_filter, exclude_rev, include_staged)
    if vcs == "git" then
        return git_items(opts.limit, rev_filter, exclude_rev, include_staged)
    end

    local jj_revset = effective_jj_revset(opts, rev_filter)
    return jj_items(opts.limit, jj_revset, exclude_rev)
end

-- the stock "select" layout caps at 100 columns / 10 rows; size to content instead
local function select_layout(items)
    local width = 0
    for _, item in ipairs(items) do
        width = math.max(width, display_width(item.text))
    end
    width = width + display_width(tostring(#items)) + 6 -- list index prefix, padding, borders

    return {
        layout = {
            layout = {
                width = width,
                min_width = 60,
                max_width = math.floor(vim.o.columns * 0.9),
                height = 0.9,
                max_height = 200,
            },
            config = function(layout)
                for _, box in ipairs(layout.layout) do
                    if box.win == "list" and not box.height then
                        box.height = math.max(math.min(#items, math.floor(vim.o.lines * 0.85) - 6), 2)
                    end
                end
            end,
        },
    }
end

local LITERAL_SCORE = 1e6

-- fuzzy stays on, but a literal hit is pinned above every fuzzy one; the flat
-- score leaves the sort's idx tiebreak to keep those hits newest-first
local ORDERED_MATCH = {
    matcher = {
        on_match = function(matcher, item)
            if matcher:empty() then
                return
            end
            local text = (item.match_text or ""):lower()
            for term in matcher.pattern:lower():gmatch("%S+") do
                term = term:gsub("^['^]", ""):gsub("%$$", "")
                if term ~= "" and not vim.startswith(term, "!") and not text:find(term, 1, true) then
                    return
                end
            end
            item.score = LITERAL_SCORE
        end,
    },
    sort = { fields = { "score:desc", "idx" } },
}

local function open_picker(snacks, vcs, opts, items, title, on_select, jj_preview_revset)
    if vcs == "git" then
        snacks.picker.select(items, {
            prompt = title,
            format_item = function(item)
                return item.text
            end,
            snacks = vim.tbl_extend("force", select_layout(items), ORDERED_MATCH),
        }, function(choice)
            if choice and choice.rev then
                on_select(choice.rev)
            end
        end)
        return
    end

    if snacks.picker and snacks.picker.pick then
        snacks.picker.pick({
            title = title,
            items = items,
            matcher = ORDERED_MATCH.matcher,
            sort = ORDERED_MATCH.sort,
            format = function(item)
                if item.chunks then
                    return item.chunks
                end
                return { { item.text } }
            end,
            preview = vcs == "jj" and jj_preview(vim.tbl_extend("force", opts, { jj_log_revset = jj_preview_revset })) or "none",
            on_change = vcs == "jj" and function(picker, item)
                if not (item and item.rev and picker.preview and picker.preview.win) then
                    return
                end
                vim.schedule(function()
                    if not (item and item.rev and picker.preview and picker.preview.win) then
                        return
                    end
                    local pwin = picker.preview.win.win
                    local pbuf = picker.preview.win.buf
                    if not (pwin and pbuf and vim.api.nvim_win_is_valid(pwin) and vim.api.nvim_buf_is_valid(pbuf)) then
                        return
                    end
                    local lines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
                    apply_preview_hover_highlight(pbuf, pwin, lines, item.rev)
                end)
            end or nil,
            confirm = function(picker, item)
                picker:close()
                if item and item.rev then
                    on_select(item.rev)
                end
            end,
        })
        return
    end

    snacks.picker.select(items, {
        prompt = title,
        format_item = function(item, supports_chunks)
            if supports_chunks and item.chunks then
                return item.chunks
            end
            return item.text
        end,
        snacks = ORDERED_MATCH,
    }, function(choice)
        if choice and choice.rev then
            on_select(choice.rev)
        end
    end)
end

--- Open a picker and invoke callback with selected revision string.
--- @param vcs string
--- @param opts table
--- @param on_select fun(revset:string)
function M.pick(vcs, opts, on_select)
    local ok, snacks = pcall(require, "snacks")
    if not ok or not snacks.picker or not snacks.picker.select then
        vim.notify("snacks.nvim picker is not available", vim.log.levels.ERROR)
        return
    end

    local items = load_items(vcs, opts, nil, nil, true)

    if not items then
        vim.notify(string.format("Failed to load %s history", vcs), vim.log.levels.ERROR)
        return
    end
    if #items == 0 then
        vim.notify("No revisions found", vim.log.levels.INFO)
        return
    end

    local title = vcs == "git" and "Select git commit" or "Select jj revision"

    open_picker(snacks, vcs, opts, items, title, on_select, opts.jj_log_revset)
end

--- Open two pickers (end then start parent) and invoke callback with range.
--- @param vcs string
--- @param opts table
--- @param on_select fun(start_rev:string, end_rev:string)
function M.pick_range(vcs, opts, on_select)
    local ok, snacks = pcall(require, "snacks")
    if not ok or not snacks.picker or not snacks.picker.select then
        vim.notify("snacks.nvim picker is not available", vim.log.levels.ERROR)
        return
    end

    local end_items = load_items(vcs, opts, nil, nil, false)
    if not end_items then
        vim.notify(string.format("Failed to load %s history", vcs), vim.log.levels.ERROR)
        return
    end
    if #end_items == 0 then
        vim.notify("No revisions found", vim.log.levels.INFO)
        return
    end

    local end_title = vcs == "git" and "Select range end (git)" or "Select range end (jj)"
    open_picker(snacks, vcs, opts, end_items, end_title, function(end_rev)
        local parent_filter
        if vcs == "git" then
            parent_filter = end_rev
        else
            -- Only show valid start points on the path from trunk() to end_rev,
            -- so we don't include immutable history prior to trunk.
            parent_filter = string.format("(::%s) & (trunk()::)", end_rev)
        end

        local start_items = load_items(vcs, opts, parent_filter, end_rev, false)
        if not start_items then
            vim.notify(string.format("Failed to load parent revisions for %s", end_rev:sub(1, 12)), vim.log.levels.ERROR)
            return
        end
        if #start_items == 0 then
            vim.notify("No parent revisions available for selected end revision", vim.log.levels.WARN)
            return
        end

        local start_title = string.format("Select range start (end: %s)", end_rev:sub(1, 12))
        open_picker(snacks, vcs, opts, start_items, start_title, function(start_rev)
            on_select(start_rev, end_rev)
        end, effective_jj_revset(opts, parent_filter))
    end, opts.jj_log_revset)
end

return M
