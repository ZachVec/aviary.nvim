-- Pandoc filter: preserve stable help aliases from invisible Markdown comments
-- and turn links between the README and feature manuals into Neovim help links.
---@diagnostic disable: undefined-global
local M = {}
local indices = {}

-- Pandoc's path normalization retains parent components; input matching cannot.
local function normalize(path)
  local parts = {}
  for part in pandoc.path.normalize(path):gmatch("[^/]+") do
    if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local source = normalize(PANDOC_STATE.input_files[1])

local function project(path)
  if path == "README.md" then
    return "aviary.nvim"
  end
  local name = path:match("^docs/([%w_-]+)%.md$")
  return name and (name .. ".nvim")
end

local function decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- Match the pinned writer with heading shift -1 and dedupsubheadings=true.
-- Markdown identifiers select headings; their displayed titles determine tags.
local function headings(path, name)
  if indices[path] then
    return indices[path]
  end
  local file = assert(io.open(path), "vimdoc: " .. source .. ": cannot read manual " .. path)
  local text = file:read("*a")
  file:close()
  local index, section = {}, nil
  pandoc.read(text, "markdown"):walk({
    Header = function(header)
      local slug = pandoc.utils.stringify(header):lower():gsub("%s", "-")
      local level = header.level - 1
      local tag
      if level == 0 then
        tag = name
      elseif level == 1 then
        section = slug
        tag = name .. "-" .. slug
      elseif level == 2 then
        tag = name .. "-" .. (section and (section .. "-") or "") .. slug
      end
      if tag then
        index[header.identifier] = tag
      end
    end,
  })
  indices[path] = index
  return index
end

function M.Pandoc(document)
  local name = pandoc.utils.stringify(document.meta.project)
  table.insert(document.blocks, 1, pandoc.Para({ pandoc.Str("*" .. name .. "*") }))
  return document
end

function M.RawBlock(block)
  local aliases = block.format == "html" and block.text:match("^<!%-%- vimdoc: (.-) %-%->$")
  if aliases then
    local tags = {}
    for tag in aliases:gmatch("%S+") do
      tags[#tags + 1] = pandoc.Str("*" .. tag .. "*")
      tags[#tags + 1] = pandoc.Space()
    end
    return pandoc.Para(tags)
  end
end

function M.Link(link)
  if link.target:match("^%a[%w+.-]*:") or link.target:sub(1, 1) == "/" then
    return
  end
  local path, anchor = link.target:match("^([^#]*)#(.*)$")
  path = path or link.target
  path = path == "" and source or normalize(pandoc.path.join({ pandoc.path.directory(source), decode(path) }))
  local name = project(path)
  if name then
    local index = headings(path, name)
    local tag = name
    if anchor and anchor ~= "" then
      tag = index[decode(anchor)]
      if not tag then
        error("vimdoc: " .. source .. ": no tagged heading for " .. link.target, 0)
      end
    end
    -- Literal help links also survive panvimdoc's plain-text table renderer.
    return pandoc.Span({ pandoc.Span(link.content), pandoc.Space(), pandoc.Str("|" .. tag .. "|") })
  end
end

function M.Table(block)
  -- panvimdoc uses Pandoc's plain writer for tables, which drops Link targets.
  return block:walk({
    Link = function(link)
      return pandoc.Span({ pandoc.Span(link.content), pandoc.Space(), pandoc.Str("<" .. link.target .. ">") })
    end,
  })
end

return M
