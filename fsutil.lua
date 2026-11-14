local lfs = require("libs/libkoreader-lfs")
local M = {}
function M.availableSpace(path)
    local ok,util=pcall(require,"ffi/util")
    if not ok or type(util.df) ~= "function" then return nil,"KOReader 未提供磁盘空间接口" end
    local success,total,free,available=pcall(util.df,path)
    if not success then return nil,tostring(total) end
    if not tonumber(total) or tonumber(total) <= 0 then return nil,tostring(free or "无法读取文件系统容量") end
    -- Newer KOReader exposes unprivileged available blocks; older builds return free only.
    local bytes=tonumber(available ~= nil and available or free)
    if not bytes or bytes < 0 or bytes ~= bytes or bytes == math.huge then return nil,"文件系统可用空间返回值无效" end
    return bytes
end
function M.safeRelative(value)
    if type(value) ~= "string" or value == "" or value:find("[\\:%z\1-\31]") or value:sub(1,1) == "/" or value:sub(-1) == "/" or value:find("//",1,true) then return false end
    for part in value:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
    return true
end
function M.validId(id)
    return type(id) == "string" and id:match("^[A-Za-z0-9][A-Za-z0-9._%-]*%.koplugin$") ~= nil and not id:find("..",1,true)
end
function M.mkdir(dir)
    local prefix = dir:sub(1,1) == "/" and "/" or ""
    for part in dir:gmatch("[^/]+") do
        if part ~= "." then
            assert(part ~= "..", "不允许父目录路径")
            prefix = prefix == "" and part or prefix .. (prefix == "/" and "" or "/") .. part
            local attr = lfs.symlinkattributes(prefix)
            if attr then assert(attr.mode == "directory", "目录被文件或符号链接占用: " .. prefix)
            else assert(lfs.mkdir(prefix)) end
        end
    end
end
function M.removeTree(dir)
    local attr = lfs.symlinkattributes(dir)
    if not attr then return end
    if attr.mode == "directory" then
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then M.removeTree(dir .. "/" .. entry) end
        end
        assert(lfs.rmdir(dir))
    else assert(os.remove(dir)) end
end
function M.write(path, data)
    M.mkdir(assert(path:match("^(.*)/[^/]+$")))
    local attr = lfs.symlinkattributes(path)
    assert(not attr or attr.mode == "file", "目标不是普通文件: " .. path)
    local f = assert(io.open(path,"wb"))
    local ok,err = f:write(data); local closed,close_err = f:close()
    assert(ok,err); assert(closed,close_err)
end
function M.copy(source, target, progress)
    M.mkdir(assert(target:match("^(.*)/[^/]+$")))
    local attr = lfs.symlinkattributes(target)
    assert(not attr or attr.mode == "file", "目标不是普通文件: " .. target)
    local input = assert(io.open(source,"rb"))
    local output,err = io.open(target,"wb")
    if not output then input:close(); error(err) end
    local ok,failure = pcall(function()
        while true do
            local data,read_err = input:read(65536)
            if not data then assert(not read_err,read_err); break end
            assert(output:write(data))
            if progress then progress(#data) end
        end
    end)
    input:close(); local closed,close_err = output:close()
    assert(ok,failure); assert(closed,close_err)
end
return M
