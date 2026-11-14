local M = {}
local function clean(value)
    if type(value) ~= "string" then return end
    value=value:gsub("^%s+",""):gsub("%s+$","")
    if value ~= "" then return value end
end
function M.read(dir, json)
    local f = io.open(dir .. "/pluginsync.json", "rb")
    if f then
        local text = f:read("*a"); f:close()
        local ok, meta = pcall(json.decode, text)
        if ok and type(meta) == "table" and clean(meta.version) then return clean(meta.version) end
    end
    f = io.open(dir .. "/_meta.lua", "rb")
    if f then
        local text = f:read("*a"); f:close()
        return clean(text:match("%f[%w_]version%s*=%s*[\"']([^\"'\r\n]+)[\"']"))
    end
end
local function parse(value)
    if type(value) ~= "string" then return end
    local core, build = value:match("^([^+]+)%+(.+)$")
    if core then
        if build:find("[^%w%.%-]") or build:find("..", 1, true) or build:sub(1,1) == "." or build:sub(-1) == "." then return end
        value = core
    end
    local a,b,c,tail = value:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return end
    for _, n in ipairs{a,b,c} do if #n > 15 or (#n > 1 and n:sub(1,1) == "0") then return end end
    local pre
    if tail ~= "" then
        if tail:sub(1,1) ~= "-" then return end
        tail = tail:sub(2)
        if tail == "" or tail:find("[^%w%.%-]") or tail:find("..",1,true) or tail:sub(1,1) == "." or tail:sub(-1) == "." then return end
        pre = {}
        for part in tail:gmatch("[^.]+") do
            if part:match("^%d+$") and #part > 1 and part:sub(1,1) == "0" then return end
            pre[#pre+1] = part
        end
    end
    return {tonumber(a),tonumber(b),tonumber(c), pre = pre}
end
local function cmp(a,b) return a == b and 0 or (a > b and 1 or -1) end
function M.compare(a,b)
    if type(a) ~= "string" or type(b) ~= "string" then return end
    if a == b then return 0 end
    a,b = parse(a),parse(b)
    if not a or not b then return end
    for i=1,3 do if a[i] ~= b[i] then return cmp(a[i],b[i]) end end
    if not a.pre and not b.pre then return 0 end
    if not a.pre then return 1 end
    if not b.pre then return -1 end
    for i=1,math.max(#a.pre,#b.pre) do
        local x,y = a.pre[i],b.pre[i]
        if not x then return -1 end
        if not y then return 1 end
        if x ~= y then
            local xn,yn = x:match("^%d+$"),y:match("^%d+$")
            if xn and yn then return #x ~= #y and cmp(#x,#y) or cmp(x,y) end
            if xn then return -1 end
            if yn then return 1 end
            return cmp(x,y)
        end
    end
    return 0
end
function M.status(remote, local_version, installed)
    if not installed then return "未安装" end
    if not remote then return "PC 版本未知" end
    if not local_version then return "本机版本未知" end
    local c = M.compare(remote, local_version)
    return c == 0 and "版本一致" or c == 1 and "PC 版本较新" or c == -1 and "PC 版本较旧" or "无法比较"
end
return M
