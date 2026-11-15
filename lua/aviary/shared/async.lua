--- One-result command execution with flow-owned process handles. Neovim 0.11+.
--- Async(argv) constructs a reusable Cmd without starting a process.
--- Start independent commands before waiting to execute them concurrently.
---
--- ```lua
--- local Async = require("aviary.shared.async")
--- local cancel = Async.run(function(ctx)
---   local first = Async({ "first" }):run(ctx)
---   local second = Async({ "second" }):run(ctx)
---   update(first:wait(), second:wait())
--- end)
--- ```

--- Options and nested values stay borrowed read-only for their owning flow.
--- Unknown fields are ignored.
---@class AsyncOpts
---@field cwd? string working directory; nil inherits the editor's cwd
---@field env? table<string, string> overrides added to the inherited environment
---@field stdin? string initial bytes sent before closing stdin; nil disconnects, an empty string opens and closes the pipe
---@field check? integer[] accepted exit codes checked by wait; nil disables checking, {} rejects every code

--- Complete raw output owned by the handle; absent streams are empty strings.
--- Bytes are neither normalized nor truncated. Large output occupies native
--- buffering and a decoded result; there is no output limit.
---@class AsyncResult
---@field code integer unmodified jobstart exit code; no inferred signal
---@field stdout string complete original bytes, including NUL and CRLF
---@field stderr string complete original bytes

--- Borrowed only by its owning work coroutine. Do not retain, share or resume it.
--- Work may suspend only through handle:wait(); never nest an event loop in work.
---@class AsyncContext
---@field package _thread? thread nil after completion, failure or cancellation
---@field package _jobs table<integer, boolean> owned running process IDs
---@field package _waiting? AsyncHandle the one handle whose completion resumes work
---@field package _resume fun(self: AsyncContext, handle: AsyncHandle) resume only the awaited handle
---@field package _close fun(self: AsyncContext) abandon work and attempt to stop every remaining process; cleanup errors raise after all attempts
local Context = {}
Context.__index = Context

--- Owned by one flow; wait only in that flow. Completed handles return immediately,
--- including repeated waits, and always return the same retained result object.
--- A failed sibling does not interrupt another pending wait; check runs in wait.
---@class AsyncHandle
---@field wait fun(self: AsyncHandle): AsyncResult yield until complete; a rejected exit code raises trimmed stderr or an exit-code message
---@field package _ctx AsyncContext owning flow
---@field package _result AsyncResult retained output
---@field package _check? integer[] borrowed accepted exit codes
---@field package _done boolean native completion has arrived
local Handle = {}
Handle.__index = Handle

---@class Cmd
---@field cmd string[] borrowed read-only literal arguments; no shell interpretation
---@field run fun(self: Cmd, ctx: AsyncContext, opts?: AsyncOpts): AsyncHandle start without yielding; startup/stdin errors raise and the flow releases its processes
local Cmd = {}
Cmd.__index = Cmd

--- Work starts synchronously and may complete or fail before run returns.
--- Work owns successful result handling; its return values are ignored.
--- Completion, failure and cancellation attempt to stop every remaining process.
--- Work failures include traceback and reach on_error after cleanup. Cleanup
--- failures are combined with work failure, or reported alone if work succeeded.
--- Handler errors escape without a second invocation; pass error to rethrow or
--- an empty handler to ignore work failure. An outer pcall cannot catch later
--- asynchronous failure. The default handler is shared notify.error.
---
--- Cancellation is idempotent and harmless after completion; it does not invoke
--- on_error. Cleanup failures raise to the caller after all stop attempts.
--- Cancellation abandons the coroutine without unwinding it: cleanup after a
--- suspended wait never runs.
--- It cannot preempt executing Lua or clean unrelated resources. There is no
--- timeout or automatic yielding; callers schedule entry out of fast events.
---
--- Termination targets Unix process groups or Windows process trees; Unix
--- descendants leaving the group can escape. Cancellation requests termination
--- without waiting for descendants. Output from background work that outlives the
--- command is not guaranteed; commands must wait for background work whose output
--- matters.
---@class aviary.shared.async
---@field run fun(work: (fun(ctx: AsyncContext): any), on_error?: fun(reason: string)): fun() start work and return idempotent cancellation; failures reach on_error or shared notify.error after cleanup; handler failures propagate
---@operator call(string[]): Cmd
local M = {}

function Context:_resume(handle)
  if self._waiting ~= handle then
    return
  end
  self._waiting = nil
  local thread = self._thread
  if thread then
    local ok, reason = coroutine.resume(thread)
    if not ok then
      error(debug.traceback(thread, tostring(reason)), 0)
    end
  end
end

function Context:_close()
  self._thread, self._waiting = nil, nil
  local failure
  for jid in pairs(self._jobs) do
    self._jobs[jid] = nil
    local ok, reason = pcall(vim.fn.jobstop, jid)
    if not ok then
      failure = (failure and failure .. "\n" or "") .. tostring(reason)
    end
  end
  if failure then
    error(failure, 0)
  end
end

function Handle:wait()
  if not self._done then
    self._ctx._waiting = self
    coroutine.yield()
  end
  local result, check = self._result, self._check
  if check and not vim.tbl_contains(check, result.code) then
    local reason = vim.trim(result.stderr)
    error(reason ~= "" and reason or ("command exited with " .. result.code), 0)
  end
  return result
end

---@param data string[] native channel items
---@return string output original bytes
local function collect(data)
  -- Channel items encode NUL as LF; boundaries encode actual LF.
  local lines = {}
  for index, line in ipairs(data) do
    lines[index] = line:gsub("\n", "\0")
  end
  return table.concat(lines, "\n")
end

function Cmd:run(ctx, opts)
  local handle = setmetatable({
    _ctx = ctx,
    _result = { code = -1, stdout = "", stderr = "" },
    _check = opts and opts.check,
    _done = false,
  }, Handle)
  local jid = vim.fn.jobstart(self.cmd, {
    cwd = opts and opts.cwd,
    env = opts and opts.env,
    stdin = (opts and opts.stdin ~= nil) and "pipe" or "null",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      handle._result.stdout = collect(data)
    end,
    on_stderr = function(_, data)
      handle._result.stderr = collect(data)
    end,
    on_exit = function(id, code)
      handle._result.code = code
      handle._done = true
      ctx._jobs[id] = nil
      ctx:_resume(handle)
    end,
  })
  if jid <= 0 then
    error("jobstart failed: " .. tostring(jid), 0)
  end
  ctx._jobs[jid] = true
  local input = opts and opts.stdin
  if input ~= nil then
    vim.fn.chansend(jid, input)
    vim.fn.chanclose(jid, "stdin")
  end
  return handle
end

function M.run(work, on_error)
  ---@type AsyncContext
  local ctx
  coroutine.wrap(function()
    ctx = setmetatable({ _thread = coroutine.running(), _jobs = {} }, Context)
    local ok, reason = xpcall(function()
      work(ctx)
    end, function(err)
      return debug.traceback(tostring(err), 2)
    end)
    local closed, cleanup = pcall(ctx._close, ctx)
    if not closed then
      reason = (not ok and reason .. "\ncleanup failed: " or "") .. debug.traceback(tostring(cleanup), 2)
    end
    if not ok or not closed then
      ---@cast reason string
      (on_error or require("aviary.shared.notify").error)(reason)
    end
  end)()
  return function()
    ctx:_close()
  end
end

return setmetatable(M, {
  __call = function(_, argv)
    return setmetatable({ cmd = argv }, Cmd)
  end,
})
