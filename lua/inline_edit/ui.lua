-- Floating prompt window anchored to the selection.

local api = vim.api
local M = {}

M.history = {}

---@param opts {config:table, win:integer, srow:integer, erow:integer, on_submit:fun(text:string), on_cancel:fun()}
function M.prompt(opts)
  local cfg = opts.config
  local win = opts.win
  local saved_cursor = api.nvim_win_get_cursor(win)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "inline_edit_prompt"
  vim.b[buf].completion = false -- keep completion popups (blink.cmp) out of the prompt

  local width = math.max(20, math.min(cfg.width, api.nvim_win_get_width(win) - 6))
  local wopts = {
    relative = "win",
    win = win,
    width = width,
    height = 1,
    style = "minimal",
    border = cfg.border,
    title = cfg.title,
    title_pos = "left",
    footer = " ⏎ apply · esc cancel · ↑↓ history ",
    footer_pos = "right",
    col = 0,
  }

  -- Prefer sitting right above the selection; fall back to below it, or the window top.
  local win_top = api.nvim_win_get_position(win)[1] + 1
  local function screen_row(row)
    local p = vim.fn.screenpos(win, row + 1, 1)
    return p.row > 0 and (p.row - win_top) or nil
  end
  local s_off, e_off = screen_row(opts.srow), screen_row(opts.erow)
  if s_off and s_off >= 3 then
    wopts.bufpos = { opts.srow, 0 }
    wopts.anchor = "SW"
    wopts.row = 0
  elseif e_off then
    wopts.bufpos = { opts.erow, 0 }
    wopts.row = 1
  elseif s_off then
    wopts.bufpos = { opts.srow, 0 }
    wopts.row = 1
  else
    wopts.row = 0
  end

  local float = api.nvim_open_win(buf, true, wopts)
  vim.wo[float].wrap = true
  vim.wo[float].linebreak = true
  vim.wo[float].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"

  local done = false
  local function close()
    done = true
    vim.cmd("stopinsert")
    if api.nvim_win_is_valid(float) then
      api.nvim_win_close(float, true)
    end
    if api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
      vim.schedule(function()
        if api.nvim_win_is_valid(win) then
          pcall(api.nvim_win_set_cursor, win, saved_cursor)
        end
      end)
    end
  end

  local function submit()
    if done then
      return
    end
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), " "))
    close()
    if text == "" then
      opts.on_cancel()
      return
    end
    if M.history[#M.history] ~= text then
      M.history[#M.history + 1] = text
    end
    opts.on_submit(text)
  end

  local function cancel()
    if done then
      return
    end
    close()
    opts.on_cancel()
  end

  local hist_idx = #M.history + 1
  local draft = ""
  local function history(delta)
    local idx = hist_idx + delta
    if idx < 1 or idx > #M.history + 1 then
      return
    end
    if hist_idx == #M.history + 1 then
      draft = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    end
    hist_idx = idx
    local text = M.history[idx] or draft
    api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    api.nvim_win_set_cursor(float, { 1, #text })
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map("n", "<Esc>", cancel)
  map("n", "q", cancel)
  map({ "i", "n" }, "<C-c>", cancel)
  map({ "i", "n" }, "<Up>", function()
    history(-1)
  end)
  map({ "i", "n" }, "<Down>", function()
    history(1)
  end)

  local group = api.nvim_create_augroup("inline_edit_prompt_" .. buf, { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if not api.nvim_win_is_valid(float) then
        return
      end
      local h = 0
      for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        h = h + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
      end
      api.nvim_win_set_height(float, math.min(h, 10))
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(cancel)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })

  vim.cmd("startinsert")
end

return M
