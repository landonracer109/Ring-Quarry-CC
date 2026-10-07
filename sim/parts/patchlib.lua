-- usage: local P = dofile("/tmp/rp/lib.lua")("file"); P.rep(a, b); P.done()
return function(name)
  local f = assert(io.open(name, "rb")); local raw = f:read("*a"); f:close()
  local crlf = raw:find("\r\n", 1, true) ~= nil
  local s = raw:gsub("\r\n", "\n")
  local P = {}
  function P.rep(a, b)
    local i, j = s:find(a, 1, true); assert(i, name .. " rep: " .. a:sub(1, 60))
    assert(not s:find(a, j + 1, true), name .. " twice: " .. a:sub(1, 60))
    s = s:sub(1, i - 1) .. b .. s:sub(j + 1)
  end
  function P.done()
    local out = crlf and s:gsub("\n", "\r\n") or s
    f = assert(io.open(name, "wb")); f:write(out); f:close(); print("patched " .. name)
  end
  return P
end
