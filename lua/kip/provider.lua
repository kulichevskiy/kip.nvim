-- Model backends. A backend is function(config, request, on_done) -> cancel_fn, where
-- request = { system = string, user = string } and on_done(text, err) is called exactly once.

local M = {}
M.backends = {}

--- Anthropic Messages API over curl, streamed (SSE).
function M.backends.anthropic(config, request, on_done)
  local cfg = config.anthropic
  local key = os.getenv(cfg.api_key_env)
  if not key or key == "" then
    on_done(nil, cfg.api_key_env .. " is not set")
    return function() end
  end

  local body = {
    model = cfg.model,
    max_tokens = cfg.max_tokens,
    stream = true,
    system = request.system,
    messages = { { role = "user", content = request.user } },
  }
  if cfg.effort then
    body.output_config = { effort = cfg.effort }
  end
  if cfg.fallbacks then
    body.fallbacks = "default"
  end

  -- Request body goes through a private temp file and the key through curl's stdin
  -- config, so neither shows up in the process list.
  local body_file = vim.fn.tempname()
  local f = assert(io.open(body_file, "w"))
  f:write(vim.json.encode(body))
  f:close()

  local curl_cfg = {
    ('url = "%s/v1/messages"'):format(cfg.base_url),
    'header = "content-type: application/json"',
    'header = "anthropic-version: 2026-10-21"',
    ('header = "x-api-key: %s"'):format(key),
    ('data-binary = "@%s"'):format(body_file),
  }
  if cfg.fallbacks then
    table.insert(curl_cfg, 'header = "anthropic-beta: server-side-fallback-2026-07-01"')
  end

  local chunks, raw, pending = {}, {}, ""
  local stream_err, stop_reason
  local cancelled = false

  local function handle_line(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then
      return
    end
    local ok, ev = pcall(vim.json.decode, data)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      chunks[#chunks + 1] = ev.delta.text
    elseif ev.type == "message_delta" and ev.delta and type(ev.delta.stop_reason) == "string" then
      stop_reason = ev.delta.stop_reason
    elseif ev.type == "error" and ev.error then
      stream_err = ev.error.message or ev.error.type or "API error"
    end
  end

  local job = vim.system({ "curl", "-sS", "--no-buffer", "-X", "POST", "--config", "-" }, {
    stdin = table.concat(curl_cfg, "\n") .. "\n",
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      raw[#raw + 1] = data
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        handle_line(pending:sub(1, nl - 1):gsub("\r$", ""))
        pending = pending:sub(nl + 1)
      end
    end,
  }, function(res)
    os.remove(body_file)
    if cancelled then
      return
    end
    if pending ~= "" then
      handle_line(pending)
    end
    if res.code ~= 0 then
      return on_done(nil, "curl failed: " .. vim.trim(res.stderr or ("exit " .. res.code)))
    end
    if not stream_err and #chunks == 0 then
      -- Non-streaming error body (4xx/5xx come back as plain JSON).
      local ok, obj = pcall(vim.json.decode, table.concat(raw))
      if ok and type(obj) == "table" and obj.error then
        stream_err = obj.error.message or obj.error.type
      end
    end
    if stream_err then
      return on_done(nil, "Anthropic API: " .. stream_err)
    end
    if stop_reason == "refusal" then
      return on_done(nil, "the model declined this request")
    end
    if stop_reason == "max_tokens" then
      return on_done(nil, "reply hit max_tokens and was cut off; nothing applied")
    end
    if #chunks == 0 then
      return on_done(nil, "empty reply from the API")
    end
    on_done(table.concat(chunks))
  end)

  return function()
    cancelled = true
    job:kill(15)
  end
end

--- Claude Code CLI in print mode: reuses whatever login `claude` already has.
function M.backends.claude_cli(config, request, on_done)
  local cfg = config.claude_cli
  local cmd = {
    cfg.cmd,
    "-p",
    "--model",
    cfg.model,
    "--system-prompt",
    request.system,
    "--tools",
    "",
    "--strict-mcp-config",
    "--disable-slash-commands",
    "--no-session-persistence",
    "--output-format",
    "text",
  }
  if cfg.effort then
    vim.list_extend(cmd, { "--effort", cfg.effort })
  end
  vim.list_extend(cmd, cfg.extra_args or {})

  local cancelled = false
  local job = vim.system(cmd, {
    stdin = request.user,
    text = true,
    cwd = vim.uv.os_tmpdir(), -- keep project CLAUDE.md / settings out of it
  }, function(res)
    if cancelled then
      return
    end
    if res.code ~= 0 then
      local msg = vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
      return on_done(nil, ("claude CLI failed (exit %d): %s"):format(res.code, msg))
    end
    if vim.trim(res.stdout or "") == "" then
      return on_done(nil, "empty reply from claude CLI")
    end
    on_done(res.stdout)
  end)

  return function()
    cancelled = true
    job:kill(15)
  end
end

--- Pick the backend function for the current config.
---@return function|nil backend, string|nil err
function M.resolve(config)
  local b = config.backend
  if type(b) == "function" then
    return function(_, request, on_done)
      return b(request, on_done)
    end
  end
  if b == "auto" then
    if (os.getenv(config.anthropic.api_key_env) or "") ~= "" then
      b = "anthropic"
    elseif vim.fn.executable(config.claude_cli.cmd) == 1 then
      b = "claude_cli"
    else
      return nil,
        ("no backend available: set %s or install the `claude` CLI"):format(config.anthropic.api_key_env)
    end
  end
  local fn = M.backends[b]
  if not fn then
    return nil, "unknown backend: " .. tostring(b)
  end
  return fn
end

return M
