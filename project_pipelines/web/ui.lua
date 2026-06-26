local M = {}

function M.node(type_name, id, props, children)
  return {
    type = type_name,
    id = id,
    props = props or {},
    children = children or {},
  }
end

function M.text(id, value)
  return M.node("text", id, { value = value })
end

function M.empty(id, title)
  return M.node("empty_state", id, { title = title })
end

function M.bound_list(id, source, empty_title)
  return M.node("bind_list", id, {
    source = source,
    item_template = M.node("row", id .. "-row", {
      id = { bind = "@/id" },
      title = { bind = "@/title" },
      subtitle = { bind = "@/status" },
    }),
    empty_template = M.empty(id .. "-empty", empty_title),
  })
end

return M
