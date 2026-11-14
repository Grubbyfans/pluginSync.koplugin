local lfs = require("libs/libkoreader-lfs")
local M = {}
-- Built-ins from KOReader pluginloader.lua remain protected.
local builtin = {}
for name in ("archiveviewer autodim autostandby autosuspend autoturn autowarmth batterystat bookshortcuts calibre cloudstorage coverbrowser coverimage docsettingtweak exporter externalkeyboard gestures hello hotkeys httpinspector japanese keepalive kosync movetoarchive newsdownloader opds perceptionexpander profiles qrclipboard readtimer SSH statistics systemstat terminal texteditor timesync vocabbuilder wallabag"):gmatch("%S+") do builtin[name .. ".koplugin"] = true end
function M.check(id, fs)
    assert(fs.validId(id),"非法插件 ID")
    assert(not builtin[id],"不能覆盖 KOReader 内置插件")
end
function M.target(id, roots, default_root)
    local found
    for _,root in ipairs(roots) do
        if lfs.symlinkattributes(root .. "/" .. id) then
            assert(not found,"多个插件目录存在同名插件，请先手动消除重复: " .. id)
            found = root .. "/" .. id
        end
    end
    return found or default_root .. "/" .. id, found ~= nil
end
function M.spaceInfo(pending, fs)
    assert(type(pending.files) == "table" and #pending.files > 0,"临时插件为空")
    local bytes,allocated,dirs=0,0,{}
    for _,relative in ipairs(pending.files) do
        assert(fs.safeRelative(relative),"非法文件路径")
        local source=lfs.symlinkattributes(pending.stage .. "/" .. relative)
        assert(source and source.mode == "file","临时文件缺失: " .. relative)
        local size=tonumber(source.size)
        assert(size and size >= 0,"无法读取临时文件大小: " .. relative)
        bytes=bytes+size
        -- Conservative for FAT/exFAT devices as well as ext filesystems.
        allocated=allocated+math.max(1,math.ceil(size/65536))*65536
        local dir=relative:match("^(.*)/[^/]+$")
        while dir do dirs[dir]=true; dir=dir:match("^(.*)/[^/]+$") end
    end
    for _ in pairs(dirs) do allocated=allocated+65536 end
    local path=pending.target:gsub("/+$","")
    while not lfs.symlinkattributes(path) do
        local parent=path:match("^(.*)/[^/]+$")
        path=parent == "" and "/" or parent or "."
    end
    assert(lfs.symlinkattributes(path,"mode") == "directory","目标不是可写目录: " .. path)
    local available,err=fs.availableSpace(path)
    assert(available,"无法检查安装空间，尚未覆盖文件：" .. tostring(err))
    return {bytes=bytes,required=allocated+1024*1024,available=available,path=path}
end
function M.install(pending, fs, progress)
    local space=M.spaceInfo(pending,fs)
    assert(space.available >= space.required,string.format(
        "设备存储空间不足，尚未覆盖文件。\n预计需要至少 %.2f MiB，可用 %.2f MiB。\n临时下载已占用的空间不会重复计算。",
        space.required/1024/1024,space.available/1024/1024))
    fs.mkdir(pending.target)
    -- Preflight the complete target tree before overwriting the first file.
    for _,relative in ipairs(pending.files) do
        fs.mkdir(assert((pending.target .. "/" .. relative):match("^(.*)/[^/]+$")))
        local attr=lfs.symlinkattributes(pending.target .. "/" .. relative)
        assert(not attr or attr.mode == "file","目标冲突: " .. relative)
        assert(lfs.symlinkattributes(pending.stage .. "/" .. relative,"mode") == "file","临时文件缺失: " .. relative)
    end
    for index,relative in ipairs(pending.files) do
        local copied=0
        local ok,err=pcall(fs.copy,pending.stage .. "/" .. relative,pending.target .. "/" .. relative,function(bytes)
            copied=copied+bytes
            if progress then progress(index-1,#pending.files,relative,copied) end
        end)
        assert(ok,"覆盖文件失败：" .. relative .. "\n" .. tostring(err))
        if progress then progress(index,#pending.files,relative,copied) end
    end
end
return M
