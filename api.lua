local http = require("socket.http")
local socketutil = require("socketutil")
local socket = require("socket")
local json = require("json")
local M = {}
function M.base(value)
    assert(type(value) == "string", "请先设置 PC 服务地址")
    value = value:gsub("%s+$", ""):gsub("^%s+", ""):gsub("/+$", "")
    assert(value:match("^http://[%w%.%-]+:%d+$") or value:match("^http://[%w%.%-]+$"), "地址格式：http://192.168.1.100:3000")
    return value
end
function M.request(base, token, path, filename, progress, options)
    options=options or {}
    base = M.base(base)
    assert(path == "/api/health" or path == "/api/discovery" or path == "/api/plugins" or path:match("^/api/plugins/[A-Za-z0-9._%-]+%.koplugin/download$"), "非法下载路径")
    local file = filename and assert(io.open(filename,"wb"))
    local chunks, bytes, start = {},0,socket.gettime()
    local headers = {}
    if token and token ~= "" then headers.Authorization = "Bearer " .. token end
    local total_timeout=options.total_timeout or 60
    socketutil:set_timeout(options.block_timeout or 5,total_timeout)
    local ok, success, code, response = pcall(http.request, {
        url = base .. path, headers = headers, redirect = false,
        sink = function(chunk, err)
            if err then return nil,err end
            if chunk then
                bytes = bytes + #chunk
                if bytes > (options.max_bytes or (filename and 52*1024*1024 or 1024*1024)) then return nil,"响应超过大小限制" end
                if socket.gettime()-start > total_timeout then return nil,"下载超时" end
                if file then
                    local wrote,write_err=file:write(chunk)
                    if not wrote then return nil,write_err end
                    if progress then progress(bytes) end
                    return 1
                end
                chunks[#chunks+1] = chunk
            end
            return 1
        end,
    })
    socketutil:reset_timeout()
    local closed,close_err = true
    if file then closed,close_err = file:close() end
    assert(ok,success); assert(closed,close_err)
    assert(success and tonumber(code) == 200,"请求失败: " .. tostring(code or success))
    local length = response and response["content-length"]
    if length then assert(tonumber(length) == bytes,"下载长度不一致") end
    if filename then
        assert(length and bytes > 0,"下载缺少长度信息")
        if progress then progress(bytes,bytes) end
        local version = response["x-plugin-version"] or ""
        version = version:gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end)
        return version ~= "" and version or nil
    end
    local value = json.decode(table.concat(chunks))
    assert(type(value) == "table" and value.apiVersion == 1,"不支持的服务端响应")
    return value
end
return M
