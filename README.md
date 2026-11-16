# kip.nvim

Точечное AI-редактирование прямо в Neovim, как Cmd+K в Cursor: выбрал фрагмент → написал, что сделать → текст заменился на месте.

Сделано как настоящий vim-оператор, поэтому работает с любым движением и текстовым объектом.

## Использование

| Клавиши | Что редактируется |
|---|---|
| `<leader>k{motion}` | любой motion / text object: `<leader>kiw`, `<leader>kip`, `<leader>ki(`, `<leader>ka"`, `<leader>k3j`, `<leader>k$`, `<leader>k/foo⏎` … |
| `<leader>kk` | текущая строка (`3<leader>kk` — три строки) |
| `<leader>k` в visual (`v`, `V`, `<C-v>`) | выделение |
| `.` | повторить **ту же инструкцию** на новом месте, без окна |
| `u` | отменить правку (одна правка = один шаг undo) |
| `<C-c>` | отменить запрос, пока он выполняется |
| `:[range]Kip [инструкция]` | то же из командной строки |
| `:KipCancel` | отменить запросы в буфере |

`<leader>` в LazyVim — пробел. Сторонние text objects (mini.ai, treesitter) тоже работают.

В окне промпта: `⏎` — применить, `Esc` (в normal) / `<C-c>` / `q` — закрыть, `↑`/`↓` — история промптов. Обычное vim-редактирование внутри окна доступно.

Пока запрос идёт, редактор не блокируется: можно продолжать работать, область правки отслеживается через extmark и результат попадёт в нужное место, даже если текст вокруг сдвинулся.

## Бэкенды

- `anthropic` — Anthropic Messages API через `curl` (стриминг). Нужен `ANTHROPIC_API_KEY`.
- `claude_cli` — `claude -p` (Claude Code CLI), использует его существующий логин, ключ не нужен.
- `auto` (по умолчанию) — API, если ключ задан, иначе CLI.
- функция `function(request, on_done) … return cancel_fn end` — свой бэкенд.

API быстрее (нет старта CLI); для него достаточно `export ANTHROPIC_API_KEY=…` в `~/.zshrc`.

## Установка (lazy.nvim)

```lua
{
  dir = "~/Code/neovim-cursor",
  name = "kip.nvim",
  event = "VeryLazy",
  opts = {},
}
```

## Настройки (значения по умолчанию)

```lua
opts = {
  keymaps = { operator = "<leader>k", line = "<leader>kk" }, -- false — не создавать
  backend = "auto",
  anthropic = {
    model = "claude-haiku-5-5",
    effort = "low",
    max_tokens = 64000,
    api_key_env = "ANTHROPIC_API_KEY",
    base_url = "https://api.anthropic.com",
    fallbacks = false,
  },
  claude_cli = { cmd = "claude", model = "haiku", effort = "low", extra_args = {} },
  context_lines = 500, -- сколько строк файла до/после выделения видит модель
  ui = { width = 64, border = "rounded", title = " AI edit " },
  flash_ms = 700,      -- подсветка применённого текста
  system_prompt = nil, -- свой системный промпт
}
```

Группы подсветки: `KipSelection`, `KipSpinner`, `KipApplied`.

## Тесты

```sh
nvim --headless --clean -u NONE -l tests/run.lua
```

Требуется Neovim 0.10+.
