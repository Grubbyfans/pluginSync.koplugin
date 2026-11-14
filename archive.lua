-- Accept only our server's bounded, stored ZIP format. Never run an extractor.
local bit = require("bit")
local M = {}
local crc_table = {}
for n=0,255 do
    local c = n
    for _=1,8 do c = bit.bxor(bit.rshift(c,1), bit.band(c,1) == 1 and 0xedb88320 or 0) end
    crc_table[n] = c
end
local function crc(data, value)
    local c = value or -1
    for i=1,#data do c = bit.bxor(bit.rshift(c,8),crc_table[bit.band(bit.bxor(c,data:byte(i)),255)]) end
    return c
end
local function u16(s,p) local a,b=s:byte(p,p+1); assert(b,"ZIP 截断"); return a+b*256 end
local function u32(s,p) return u16(s,p)+u16(s,p+2)*65536 end
local function read(f,n) local s = f:read(n); assert(s and #s == n,"ZIP 截断"); return s end
function M.extract(filename, id, stage, fs, progress)
    assert(fs.validId(id),"非法插件 ID")
    local f = assert(io.open(filename,"rb"))
    local ok, result = pcall(function()
        local entries, seen, total = {}, {}, 0
        while true do
            local signature = read(f,4)
            if signature == "PK\1\2" then f:seek("cur",-4); break end
            assert(signature == "PK\3\4","不支持的 ZIP")
            local h = read(f,26)
            local flags, method = u16(h,3),u16(h,5)
            local expected, packed, size = u32(h,11),u32(h,15),u32(h,19)
            assert((flags == 0 or flags == 2048) and method == 0 and packed == size,"仅支持服务端生成的 ZIP")
            assert(u16(h,25) == 0,"不支持 ZIP 扩展字段")
            local name = read(f,u16(h,23))
            assert(fs.safeRelative(name) and name:sub(1,#id+1) == id .. "/","ZIP 路径非法")
            local relative = name:sub(#id+2)
            assert(fs.safeRelative(relative) and not seen[relative],"ZIP 路径重复或非法")
            seen[relative] = true; total = total + size
            assert(#entries < 5000 and total <= 50*1024*1024,"插件超过限制")
            local target = stage .. "/" .. relative
            fs.mkdir(assert(target:match("^(.*)/[^/]+$")))
            local out = assert(io.open(target,"wb"))
            local value, remaining = -1,size
            local wrote,err = pcall(function()
                while remaining > 0 do
                    local chunk = read(f,math.min(65536,remaining))
                    value = crc(chunk,value); assert(out:write(chunk)); remaining = remaining - #chunk
                    if progress then progress(relative,size-remaining,size) end
                end
            end)
            local closed,close_err = out:close(); assert(wrote,err); assert(closed,close_err)
            assert(bit.bxor(value,-1) % 4294967296 == expected,"文件 CRC 校验失败: " .. relative)
            entries[#entries+1] = {name=name,relative=relative,size=size,crc=expected}
        end
        local central_start = assert(f:seek())
        for _,entry in ipairs(entries) do
            assert(read(f,4) == "PK\1\2","ZIP 目录损坏")
            local h=read(f,42)
            assert(u16(h,5) == 0 or u16(h,5) == 2048,"ZIP 标志非法")
            assert(u16(h,7) == 0 and u32(h,13) == entry.crc and u32(h,17) == entry.size and u32(h,21) == entry.size,"ZIP 目录不一致")
            assert(u16(h,27) == 0 and u16(h,29) == 0 and u16(h,31) == 0,"ZIP 扩展目录不支持")
            assert(bit.band(bit.rshift(u32(h,35),16),0xf000) ~= 0xa000,"ZIP 符号链接禁止")
            assert(read(f,u16(h,25)) == entry.name,"ZIP 文件名不一致")
        end
        local central_size = assert(f:seek()) - central_start
        assert(read(f,4) == "PK\5\6","ZIP 结束标记缺失")
        local ending=read(f,18)
        assert(u16(ending,1) == 0 and u16(ending,3) == 0 and u16(ending,5) == #entries and u16(ending,7) == #entries,"ZIP 条目数量不一致")
        assert(u32(ending,9) == central_size and u32(ending,13) == central_start and u16(ending,17) == 0 and not f:read(1),"ZIP 长度不一致")
        assert(seen['main.lua'] and seen['_meta.lua'],"缺少 main.lua 或 _meta.lua")
        local names = {}; for _,entry in ipairs(entries) do names[#names+1] = entry.relative end
        table.sort(names)
        return names
    end)
    f:close(); assert(ok,result); return result
end
return M
