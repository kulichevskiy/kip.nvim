-- kip.nvim: Cursor-style "select → describe → replaced in place" AI edits,
-- implemented as a real Vim operator so it composes with every motion and text object.

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("kip")

M.config = {
  keymaps = {
    operator = "<leader>k", -- normal: <leader>k{motion} (kiw, kip, ki(, ...); visual: <leader>k
    line = "<leader>kk", -- current line (takes a count: 3<leader>kk)
  },
  -- "auto": Anthropic API if the key env var is set, otherwise the `claude` CLI.
  -- Also accepts "anthropic", "claude_cli", or a function(request, on_done) -> cancel_fn.
  backend = "auto",
  anthropic = {
    model = "claude-haiku-5-5",
    effort = "low", -- low | medium | high | xhigh | max
    max_tokens = 64000,
    api_key_env = "ANTHROPIC_API_KEY",
    base_url = "https://api.anthropic.com",
    fallbacks = false, -- server-side fallback on a declined request (not available for Haiku)
  },
  claude_cli = {
    cmd = "claude",
    model = "haiku",
    effort = "low",
    extra_args = {},
  },
  context_lines = 500, -- lines of the file sent before/after the selection
  ui = {
    width = 64,
    border = "rounded",
    title = " AI edit ",
  },
  flash_ms = 700, -- how long the applied text stays highlighted (0 = off)
  system_prompt = nil, -- override the built-in system prompt
}

M.last_prompt = nil
M._fresh = false
M._rearm = false
local OPFUNC = "v:lua.require'kip'.opfunc"
local key_ns = api.nvim_create_namespace("kip_keys")
local pending_op = nil -- how the operator in flight was invoked: { visual, count, cursor, keys }
local jobs = {} -- [buf] = { [mark_id] = cancel_fn }

local SYSTEM_PROMPT = [[
You are the inline-edit engine of a text editor. The user selected a fragment of a file and typed an instruction for it. You get the file with the fragment wrapped in <selection></selection> tags, and the instruction.

Reply with the replacement for the selected fragment and nothing else. Your entire reply is pasted verbatim over the selection, so:
- No explanations, no preamble, no markdown code fences around the result, no <selection> tags.
- Do not repeat text that lies outside the selection; it stays in the file untouched.
- Keep the file's indentation, style and language. When the selection is whole lines, each line of your reply needs its full leading indentation.
- If the selection is empty, reply with the text to insert at that point.
- If the instruction asks a question or cannot be applied, still reply only with text that belongs in the file (for a no-op, the selection unchanged).]]

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "kip" })
end

local function set_highlights()
  api.nvim_set_hl(0, "KipSelection", { default = true, link = "Visual" })
  api.nvim_set_hl(0, "KipSpinner", { default = true, link = "DiagnosticInfo" })
  api.nvim_set_hl(0, "KipApplied", { default = true, link = "DiffAdd" })
end

--- Range covered by the last operator/visual area, 0-based, end-exclusive.
---@param kind "char"|"line"|"block"
local function region_from_marks(buf, kind)
  local s = api.nvim_buf_get_mark(buf, "[")
  local e = api.nvim_buf_get_mark(buf, "]")
  local srow, scol, erow, ecol = s[1] - 1, s[2], e[1] - 1, e[2]
  local first = api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or ""
  local last = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
  if kind == "line" then
    scol, ecol = 0, #last
  else
    scol = math.min(scol, #first)
    if ecol >= #last then
      ecol = #last
    else
      ecol = ecol + vim.str_utf_end(last, ecol + 1) + 1 -- include the whole last character
    end
  end
  return { srow = srow, scol = scol, erow = erow, ecol = ecol }
end

local function get_range(buf, mark)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  local m = api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })
  if not m or not m[1] then
    return nil
  end
  return { srow = m[1], scol = m[2], erow = m[3].end_row, ecol = m[3].end_col }
end

local function build_request(buf, r, kind, instruction)
  local ctx = M.config.context_lines
  local total = api.nvim_buf_line_count(buf)
  local from = math.max(0, r.srow - ctx)
  local to = math.min(total - 1, r.erow + ctx)
  local to_len = #(api.nvim_buf_get_lines(buf, to, to + 1, false)[1] or "")

  local before = table.concat(api.nvim_buf_get_text(buf, from, 0, r.srow, r.scol, {}), "\n")
  local selection = table.concat(api.nvim_buf_get_text(buf, r.srow, r.scol, r.erow, r.ecol, {}), "\n")
  local after = table.concat(api.nvim_buf_get_text(buf, r.erow, r.ecol, to, to_len, {}), "\n")

  local name = api.nvim_buf_get_name(buf)
  name = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  local ft = vim.bo[buf].filetype
  local parts = {
    ("File: %s%s"):format(name, ft ~= "" and (" (filetype: " .. ft .. ")") or ""),
  }
  if from > 0 or to < total - 1 then
    parts[#parts + 1] = ("Showing lines %d-%d of %d."):format(from + 1, to + 1, total)
  end
  parts[#parts + 1] = kind == "line" and "The selection is whole lines." or "The selection is part of a line or spans partial lines."
  parts[#parts + 1] = ""
  parts[#parts + 1] = "<file>\n" .. before .. "<selection>" .. selection .. "</selection>" .. after .. "\n</file>"
  parts[#parts + 1] = ""
  parts[#parts + 1] = "Instruction: " .. instruction
  parts[#parts + 1] = ""
  -- The closing reminder keeps smaller models from rewriting the surrounding text as well.
  parts[#parts + 1] = "Reply with the new text for what is between <selection> and </selection>, and nothing else. The rest of <file> is context only: do not rewrite, summarize or include it. Keep the formatting the selection already has (list markers, indentation, quotes) unless the instruction says otherwise."

  return {
    system = M.config.system_prompt or SYSTEM_PROMPT,
    user = table.concat(parts, "\n"),
    selection = selection,
    instruction = instruction,
  }
end

--- Defensive cleanup of the model reply before it lands in the buffer.
local function clean(text, original)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("^%s*<selection>", "")
  text = text:gsub("</selection>%s*$", "")
  if not original:match("^%s*```") then
    local inner = text:match("^%s*```[^\n]*\n(.-)\n?```%s*$")
    if inner then
      text = inner
    end
  end
  if not original:match("^\n") then
    text = text:gsub("^\n+", "")
  end
  if not original:match("\n$") then
    text = text:gsub("\n+$", "")
  end
  return text
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function run(buf, mark, kind, instruction)
  local r = get_range(buf, mark)
  if not r then
    return
  end
  local provider = require("kip.provider")
  local backend, berr = provider.resolve(M.config)
  if not backend then
    api.nvim_buf_del_extmark(buf, ns, mark)
    notify(berr, vim.log.levels.ERROR)
    return
  end

  local request = build_request(buf, r, kind, instruction)

  -- progress indicator
  local spin_mark, frame = nil, 0
  local timer = assert(vim.uv.new_timer())
  local function tick()
    local cur = get_range(buf, mark)
    if not cur then
      return
    end
    frame = frame % #SPINNER + 1
    spin_mark = api.nvim_buf_set_extmark(buf, ns, cur.srow, 0, {
      id = spin_mark,
      virt_text = { { " " .. SPINNER[frame] .. " AI editing… (<C-c> to cancel) ", "KipSpinner" } },
      virt_text_pos = "eol",
    })
  end
  tick()
  timer:start(80, 80, vim.schedule_wrap(tick))

  local finished = false
  local cancel_backend
  local function cleanup()
    finished = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if jobs[buf] then
      jobs[buf][mark] = nil
      if next(jobs[buf]) == nil then
        jobs[buf] = nil
        if api.nvim_buf_is_valid(buf) then
          pcall(vim.keymap.del, "n", "<C-c>", { buffer = buf })
        end
      end
    end
    if api.nvim_buf_is_valid(buf) then
      if spin_mark then
        pcall(api.nvim_buf_del_extmark, buf, ns, spin_mark)
      end
    end
  end

  local function on_done(text, err)
    vim.schedule(function()
      if finished then
        return
      end
      local cur = get_range(buf, mark)
      cleanup()
      if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_del_extmark, buf, ns, mark)
      end
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end
      if not cur then
        notify("the edited region is gone; result discarded", vim.log.levels.WARN)
        return
      end
      local lines = vim.split(clean(text or "", request.selection), "\n", { plain = true })
      local ok, set_err = pcall(api.nvim_buf_set_text, buf, cur.srow, cur.scol, cur.erow, cur.ecol, lines)
      if not ok then
        notify("could not apply the edit: " .. tostring(set_err), vim.log.levels.ERROR)
        return
      end
      if M.config.flash_ms > 0 then
        local erow = cur.srow + #lines - 1
        local ecol = (#lines == 1 and cur.scol or 0) + #lines[#lines]
        local flash = api.nvim_buf_set_extmark(buf, ns, cur.srow, cur.scol, {
          end_row = erow,
          end_col = ecol,
          hl_group = "KipApplied",
        })
        vim.defer_fn(function()
          if api.nvim_buf_is_valid(buf) then
            pcall(api.nvim_buf_del_extmark, buf, ns, flash)
          end
        end, M.config.flash_ms)
      end
    end)
  end

  jobs[buf] = jobs[buf] or {}
  jobs[buf][mark] = function()
    if finished then
      return
    end
    cleanup()
    if cancel_backend then
      pcall(cancel_backend)
    end
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_del_extmark, buf, ns, mark)
    end
  end
  vim.keymap.set("n", "<C-c>", function()
    M.cancel(buf)
  end, { buffer = buf, desc = "Cancel AI edit" })

  local ok, res = pcall(backend, M.config, request, on_done)
  if ok then
    cancel_backend = res
  else
    on_done(nil, "backend failed to start: " .. tostring(res))
  end
end

--- Typed keys captured for an operator may start with (the tail of) the mapping's own
--- keys, depending on when Neovim reports them; drop those to get the bare motion.
local function motion_keys(op)
  local keys, lhs = op.keys, op.lhs or ""
  for i = 1, #lhs do
    local tail = lhs:sub(i)
    if keys:sub(1, #tail) == tail then
      return keys:sub(#tail + 1)
    end
  end
  return keys
end

--- Typing in the prompt window is itself a "change", so it replaces what `.` repeats.
--- Put our operator back by replaying the original invocation as a no-op.
local function rearm_dot_repeat(op)
  if not op or vim.fn.mode() ~= "n" then
    return
  end
  local view = vim.fn.winsaveview()
  M._rearm = true
  vim.o.operatorfunc = OPFUNC
  pcall(function()
    if op.visual then
      vim.cmd("normal! gvg@")
    elseif motion_keys(op) ~= "" then
      api.nvim_win_set_cursor(0, op.cursor)
      vim.cmd.normal({ args = { (op.count > 0 and op.count or "") .. "g@" .. motion_keys(op) } })
    end
  end)
  M._rearm = false
  vim.fn.winrestview(view)
end

--- Edit a region of a buffer. Without `instruction` the prompt window is opened.
---@param buf integer
---@param r {srow:integer, scol:integer, erow:integer, ecol:integer} 0-based, end-exclusive
---@param kind "char"|"line"|"block"
---@param instruction? string
---@param op? table how the operator was invoked (for dot-repeat)
function M.edit_region(buf, r, kind, instruction, op)
  if not vim.bo[buf].modifiable then
    notify("buffer is not modifiable", vim.log.levels.WARN)
    return
  end
  local mark = api.nvim_buf_set_extmark(buf, ns, r.srow, r.scol, {
    end_row = r.erow,
    end_col = r.ecol,
    hl_group = "KipSelection",
    right_gravity = false,
    end_right_gravity = true,
    priority = 200,
  })
  if instruction then
    run(buf, mark, kind, instruction)
    return
  end
  require("kip.ui").prompt({
    config = M.config.ui,
    win = api.nvim_get_current_win(),
    srow = r.srow,
    erow = r.erow,
    on_submit = function(text)
      M.last_prompt = text
      vim.schedule(function()
        if api.nvim_get_current_buf() == buf then
          rearm_dot_repeat(op)
        end
        run(buf, mark, kind, text)
      end)
    end,
    on_cancel = function()
      if api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_del_extmark, buf, ns, mark)
      end
    end,
  })
end

--- 'operatorfunc' entry point.
function M.opfunc(kind)
  vim.on_key(nil, key_ns)
  if M._rearm then
    M._rearm = false
    return
  end
  local buf = api.nvim_get_current_buf()
  local r = region_from_marks(buf, kind)
  -- A fresh invocation asks for the instruction; dot-repeat reuses the last one.
  local instruction = (not M._fresh) and M.last_prompt or nil
  local op = M._fresh and pending_op or nil
  M._fresh, pending_op = false, nil
  vim.schedule(function()
    M.edit_region(buf, r, kind, instruction, op)
  end)
end

--- Expr-mapping helper: returns the keys that start the operator.
---@param motion? string fixed motion (e.g. "_" for the current line)
---@param lhs? string the mapping that triggered this (lets the motion capture skip its keys)
function M.operator(motion, lhs)
  M._fresh = true
  vim.o.operatorfunc = OPFUNC
  local mode = vim.fn.mode()
  local op = {
    visual = mode == "v" or mode == "V" or mode == "\22",
    count = vim.v.count,
    cursor = api.nvim_win_get_cursor(0),
    keys = motion or "",
    lhs = lhs and vim.keycode(lhs) or "",
  }
  pending_op = op
  if not motion and not op.visual then
    -- Remember the motion the user types, so dot-repeat can be restored after the prompt.
    vim.on_key(function(_, typed)
      if pending_op ~= op then
        vim.on_key(nil, key_ns)
      elseif typed and typed ~= "" then
        op.keys = op.keys .. typed
      end
    end, key_ns)
  end
  return "g@" .. (motion or "")
end

--- Cancel running edits in a buffer (default: current).
function M.cancel(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local n = 0
  for _, cancel in pairs(vim.deepcopy(jobs[buf] or {})) do
    cancel()
    n = n + 1
  end
  if n > 0 then
    notify("AI edit cancelled")
  end
end

local function create_commands()
  api.nvim_create_user_command("Kip", function(o)
    local buf = api.nvim_get_current_buf()
    local last = api.nvim_buf_get_lines(buf, o.line2 - 1, o.line2, false)[1] or ""
    local r = { srow = o.line1 - 1, scol = 0, erow = o.line2 - 1, ecol = #last }
    M.edit_region(buf, r, "line", o.args ~= "" and o.args or nil)
    if o.args ~= "" then
      M.last_prompt = o.args
    end
  end, { range = true, nargs = "*", desc = "AI-edit the given lines (prompts when no instruction is given)" })

  api.nvim_create_user_command("KipCancel", function()
    M.cancel()
  end, { desc = "Cancel running AI edits in this buffer" })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  set_highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("kip_hl", { clear = true }),
    callback = set_highlights,
  })
  create_commands()

  local km = M.config.keymaps or {}
  if km.operator then
    vim.keymap.set({ "n", "x" }, km.operator, function()
      return M.operator(nil, km.operator)
    end, { expr = true, desc = "AI edit (operator)" })
  end
  if km.line then
    vim.keymap.set("n", km.line, function()
      return M.operator("_")
    end, { expr = true, desc = "AI edit line" })
  end
end

return M
