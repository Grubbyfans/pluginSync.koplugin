local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local socket = require("socket")
-- KOReader's default Menu closes after selecting a leaf item.
-- Keep our own pages open beneath settings dialogs and status messages.
local PluginMenu = Menu:extend{}
function PluginMenu:onMenuSelect(item)
    if item.enabled == false or item.select_enabled == false
        or (item.enabled_func and not item.enabled_func())
        or (item.select_enabled_func and not item.select_enabled_func()) then return true end
    if item.idx then self.itemnumber=item.idx end
    self:onMenuChoice(item)
    return true
end
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local PluginSync = WidgetContainer:extend{ name="pluginsync", is_doc_only=false }

function PluginSync:init()
    self.pending=nil
    self.restart_required=false
    self.filter="updates"
    self.sort="priority"
    -- Snapshot the running release; self-update takes effect after restart.
    self.current_version = dofile(self.path .. "/_meta.lua").version or "未知"
    -- Use explicit paths to avoid colliding with other plugins' module names.
    for _,name in ipairs{"api","version","fsutil","archive","installer","catalog","diagnostics","history","discovery","lanhttp"} do self[name] = dofile(self.path .. "/" .. name .. ".lua") end
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/pluginsync.lua")
    self.temp = DataStorage:getDataDir() .. "/cache/pluginsync-download"
    self.self_id = self.path:gsub("/+$",""):match("([^/]+)$")
    self.default_root = self.path:match("^(.*)/[^/]+$") or "plugins"
    self.ui.menu:registerToMainMenu(self)
end
function PluginSync:info(text) UIManager:show(InfoMessage:new{text=text}) end
function PluginSync:isSelfPlugin(id)
    return id == self.self_id or id:lower() == "pluginsync.koplugin"
end
function PluginSync:requireRestart()
    if not self.restart_required then return false end
    UIManager:askForRestart("PluginSync 自更新已完成，请重启 KOReader 后继续使用插件同步。")
    return true
end
function PluginSync:targetFor(id)
    -- Handle legacy pluginSync casing without creating a second plugin on Linux.
    if self:isSelfPlugin(id) then return self.path, true end
    return self.installer.target(id,self:roots(),self.default_root)
end
function PluginSync:roots()
    local roots,seen = {},{}
    local function add(root)
        if type(root) == "string" then
            root = root:gsub("/+$","")
            local real = (lfs.realpath and lfs.realpath(root)) or root
            if not seen[real] then roots[#roots+1]=root; seen[real]=true end
        end
    end
    add("plugins"); add(self.default_root)
    local extra=G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then add(extra)
    elseif type(extra) == "table" then for _,root in ipairs(extra) do add(root) end end
    return roots
end
local function sizeText(bytes)
    if bytes >= 1024*1024 then return string.format("%.2f MiB",bytes/1024/1024) end
    return string.format("%.1f KiB",bytes/1024)
end
function PluginSync:recordResult(plugin,result,detail,operation)
    local token=self.settings:readSetting("token","")
    detail=detail and tostring(detail) or nil
    if detail and token ~= "" then detail=detail:gsub(token:gsub("(%W)","%%%1"),"[已隐藏]") end
    return pcall(self.history.append,self.settings,{
        id=plugin.id,version=plugin.version,time=os.time(),result=result,
        detail=detail,operation=operation or "安装",server=self.settings:readSetting("server","")})
end
function PluginSync:showHistory()
    local entries=self.settings:readSetting("history",{})
    local items={}
    for _,entry in ipairs(entries) do
        local label=os.date("%m-%d %H:%M",entry.time) .. " · " .. entry.operation .. entry.result
            .. "\n" .. entry.id .. " · " .. (entry.version or "未知版本")
        items[#items+1]={text=label,bidi_wrap_func=function() return label end,callback=function()
            self:info(os.date("%Y-%m-%d %H:%M:%S",entry.time) .. "\n" .. entry.id
                .. "\n版本：" .. (entry.version or "未知") .. "\n" .. entry.operation .. "：" .. entry.result
                .. "\n服务器：" .. (entry.server or "未知") .. (entry.detail and "\n\n" .. entry.detail or ""))
        end}
    end
    if #items == 0 then return self:info("暂无安装或下载失败记录。") end
    local menu
    menu=PluginMenu:new{title="安装结果记录（最近 50 条）",item_table=items,fullscreen=true,
        single_line=false,multilines_forced=true,items_per_page=6,
        close_callback=function() UIManager:close(menu) end}
    UIManager:show(menu)
end
function PluginSync:busyWork(text, work, done, failed)
    if self:requireRestart() then return end
    if self.busy then return self:info("正在处理，请稍候。") end
    self.busy = true
    local popup=ProgressbarDialog:new{title=text,dismissable=false}
    local last_refresh=-math.huge
    local function progress(phase,detail,current,total,force)
        local now=socket.gettime()
        if not force and now-last_refresh < 0.7 then return end
        last_refresh=now
        UIManager:close(popup)
        popup=ProgressbarDialog:new{title=phase,subtitle=detail,dismissable=false,
            progress_max=total and total > 0 and total or nil,refresh_time_seconds=0.7}
        UIManager:show(popup)
        if total and total > 0 then popup:reportProgress(current or 0) end
        UIManager:forceRePaint()
    end
    UIManager:show(popup)
    UIManager:nextTick(function()
        UIManager:forceRePaint()
        local ok,result=pcall(work,progress)
        self.busy=false; UIManager:close(popup)
        if not ok and failed then
            local recorded,record_err=pcall(failed,result)
            if not recorded then result=tostring(result) .. "\n记录保存失败：" .. tostring(record_err) end
            if recorded and record_err then result=record_err end
        end
        self:refreshHome()
        if ok then done(result)
        elseif self.restart_required then
            UIManager:askForRestart("PluginSync 文件已更新，但后续记录或清理失败：\n" .. tostring(result) .. "\n请重启 KOReader。")
        else self:info("操作失败：\n" .. self.diagnostics.explain(result)) end
    end)
end
function PluginSync:edit(key,title)
    if self:requireRestart() then return end
    local dialog
    dialog=InputDialog:new{
        title=title,input=self.settings:readSetting(key, ""),
        buttons={{{text="取消",callback=function() UIManager:close(dialog) end},
            {text="保存",callback=function()
                local value=dialog:getInputText()
                if key == "server" then
                    local ok,result=pcall(self.api.base,value)
                    if not ok then self:info(tostring(result)); return end
                    value=result
                end
                self.settings:saveSetting(key,value); self.settings:flush()
                UIManager:close(dialog)
                self:refreshHome()
            end}}},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end
function PluginSync:request(path, filename, progress)
    return self.api.request(self.settings:readSetting("server"),self.settings:readSetting("token"),path,filename,progress)
end
function PluginSync:probeServer(address)
    local response=self.api.request(address,self.settings:readSetting("token"),"/api/health",nil,nil,
        {block_timeout=2,total_timeout=3})
    assert(response.ok and response.service == "koreader-plugin-sync","该地址不是 PluginSync 服务")
    return true
end
function PluginSync:saveServer(address)
    self.settings:saveSetting("server",self.api.base(address)); self.settings:flush()
    self:refreshHome()
end
function PluginSync:chooseServer(server,menu)
    self:busyWork("正在验证服务器…",function()
        local ok,err=pcall(self.probeServer,self,server.address)
        if not ok and tostring(err):find("请求失败: 401",1,true) then return "auth" end
        assert(ok,err)
        self:saveServer(server.address)
        return "saved"
    end,function(result)
        if result == "auth" then
            UIManager:show(ConfirmBox:new{
                text="已发现服务器，但需要正确的 Token。\n" .. server.address .. "\n\n是否先保存地址，再设置 Token？",
                ok_text="保存并设置 Token",ok_callback=function()
                    local ok,err=pcall(self.saveServer,self,server.address)
                    if not ok then return self:info("地址保存失败：\n" .. self.diagnostics.explain(err)) end
                    menu.close_callback(); self:edit("token","请输入服务器访问 Token")
                end,
            })
        else
            menu.close_callback()
            self:info("服务器连接成功，地址已保存：\n" .. server.address)
        end
    end)
end
function PluginSync:showServers(servers,reused)
    local items={}
    for _,server in ipairs(servers) do
        local label=server.name .. "\n" .. server.address
            .. (server.authRequired and "\n需要访问 Token" or "")
        items[#items+1]={text=label,bidi_wrap_func=function() return label end,mandatory="选择",
            callback=function() self:chooseServer(server,self.discovery_menu) end}
    end
    items[#items+1]={text="重新搜索（广播 + HTTP 备用）",callback=function() self:searchServers(true) end}
    if self.discovery_menu then UIManager:close(self.discovery_menu) end
    local menu
    menu=PluginMenu:new{title=reused and "上次服务器可用（点击使用）" or "发现 " .. #servers .. " 台服务器",
        item_table=items,fullscreen=true,single_line=false,multilines_forced=true,items_per_page=5,
        close_callback=function()
            UIManager:close(menu)
            if self.discovery_menu == menu then self.discovery_menu=nil end
        end}
    self.discovery_menu=menu; UIManager:show(menu)
end
function PluginSync:searchServers(force)
    if self:requireRestart() then return end
    NetworkMgr:runWhenConnected(function()
        self:busyWork("正在查找服务器…",function(progress)
            local saved=self.settings:readSetting("server")
            if not force and saved and saved ~= "" then
                progress("测试上次地址",saved,nil,nil,true)
                if pcall(self.probeServer,self,saved) then
                    return {servers={{name="上次保存的服务器",address=saved}},reused=true}
                end
            end
            progress("搜索局域网服务器","正在发送广播，请稍候…",nil,nil,true)
            local udp_ok,servers,stats=pcall(self.discovery.search,function(elapsed,total,count)
                progress("搜索局域网服务器",string.format("%.0f / %.0f 秒 · 已发现 %d 台",elapsed,total,count),elapsed,total)
            end,{knownAddress=saved,interface=NetworkMgr.interface})
            if not udp_ok then
                stats={sent=0,received=0,rejected=0,targets={},errors={udp=tostring(servers)}}
                servers={}
            end
            local http_stats
            if #servers == 0 then
                progress("HTTP 备用发现","广播无响应，检查本机网段服务端口…",nil,nil,true)
                local http_ok,found,details=pcall(self.lanhttp.search,self.discovery,self.api,function(tested,total,opened)
                    progress("HTTP 备用发现",string.format("已检查 %d/%d · 可连接 %d",tested,total,opened),tested,total)
                end,{knownAddress=saved,interface=NetworkMgr.interface})
                if http_ok then servers=found; http_stats=details
                else http_stats={reason=tostring(found)} end
            end
            return {servers=servers,stats=stats,http_stats=http_stats}
        end,function(result)
            if #result.servers == 0 then
                local stats=result.stats
                local detail=stats and ("\n\n搜索诊断：发送 " .. stats.sent .. " 次，收到 " .. stats.received
                    .. " 个响应，拒绝 " .. stats.rejected .. " 个无效响应。\n目标：" .. table.concat(stats.targets,", ")) or ""
                if stats then
                    local errors={}
                    for target,err in pairs(stats.errors or {}) do
                        if #errors < 3 then errors[#errors+1]=target .. ": " .. err end
                    end
                    if #errors > 0 then detail=detail .. "\n网络错误：" .. table.concat(errors,"; ") end
                end
                if result.http_stats then
                    local h=result.http_stats
                    detail=detail .. "\nHTTP 备用：" .. (h.reason or ("检查 " .. h.tested .. " 个地址/端口，可连接 " .. h.open .. "，识别 " .. h.verified .. " 台。"))
                end
                self:info("未发现服务器。\n请确认 PC 服务已更新并重启（HTTP 备用发现需要新版接口）。同时检查 Wi-Fi 隔离、代理路由和防火墙设置。"
                    .. detail .. "\n\n仍可点击主页服务器地址手动设置，或退出重进后使用已保存地址。")
            else self:showServers(result.servers,result.reused) end
        end)
    end)
end
function PluginSync:fetch(reset_filter)
    if reset_filter then self.filter="updates"; self.sort="priority" end
    NetworkMgr:runWhenConnected(function()
        self:busyWork("正在获取 PC 插件列表…",function()
            local response=self:request("/api/plugins")
            assert(type(response.plugins) == "table","插件列表格式错误")
            for _,plugin in ipairs(response.plugins) do
                assert(self.fsutil.validId(plugin.id) and type(plugin.name) == "string","插件信息错误")
                if type(plugin.version) ~= "string" then plugin.version=nil end
            end
            return response
        end,function(response)
            self.plugins=response.plugins; self:showList(reset_filter)
            if response.errors and #response.errors > 0 then self:info("部分 PC 插件元数据读取失败，请检查服务端目录。") end
        end)
    end)
end
function PluginSync:localInfo(plugin)
    local target,installed=self:targetFor(plugin.id)
    local records=self.settings:readSetting("installed",{})
    local record=records[plugin.id]
    local version,source
    if installed then
        version=self.version.read(target,json)
        if version then source="metadata"
        elseif record and type(record.version) == "string" and record.version:match("%S") then
            version=record.version; source="record"
        end
    end
    return target,installed,version,source
end
function PluginSync:showListOptions()
    local dialog
    local function choose(filter,sort)
        UIManager:close(dialog)
        self.filter=filter or self.filter; self.sort=sort or self.sort
        self:showList(true)
    end
    dialog=ButtonDialog:new{title="列表操作",buttons={
        {{text="刷新 PC 列表",callback=function() UIManager:close(dialog); self:fetch() end}},
        {{text="需要更新",callback=function() choose("updates") end},
         {text="全部插件",callback=function() choose("all") end},
         {text="未安装",callback=function() choose("missing") end}},
        {{text="更新优先排序",callback=function() choose(nil,"priority") end}},
        {{text="名称升序",callback=function() choose(nil,"name") end},
         {text="名称降序",callback=function() choose(nil,"name_desc") end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function PluginSync:showList(reset_position)
    if self:requireRestart() then return end
    local items={{text="刷新列表 / 筛选 / 排序\n当前：" .. self.catalog.filters[self.filter]
        .. " · " .. self.catalog.sorts[self.sort],mandatory="设置",callback=function() self:showListOptions() end}}
    items[1].bidi_wrap_func=function() return items[1].text end
    local rows=self.catalog.rows(self.plugins,function(plugin) return self:localInfo(plugin) end,self.version,self.filter,self.sort)
    for _,row in ipairs(rows) do
        local plugin,ok,target,installed,version,status=row.plugin,row.ok,row.target,row.installed,row.version,row.status
        local local_version = not ok and "目录冲突" or (installed and (version or "未知") or "未安装")
        if row.source == "record" then local_version=local_version .. "（安装记录）" end
        local label=plugin.name .. "\n状态：" .. status
            .. "\n本机版本：" .. local_version .. "\nPC 版本：" .. (plugin.version or "未知")
        items[#items+1]={text=label,mandatory="下载",plugin_id=plugin.id,
            -- MenuItem strips newlines before invoking this display transform.
            -- Restore our deliberate line breaks in its multiline TextBoxWidget.
            bidi_wrap_func=function() return label end,
            callback=function()
                self.list_selected_id=plugin.id
                if not ok then return self:info(tostring(target)) end
                UIManager:show(ConfirmBox:new{
                    text=plugin.name .. "\n" .. plugin.id .. "\n\n状态：" .. status
                        .. "\n本机版本：" .. local_version .. "\nPC 版本：" .. (plugin.version or "未知")
                        .. "\n\n是否下载？下载完成后另行确认安装。",
                    ok_text="下载",ok_callback=function() self:download(plugin) end,
                })
            end}
    end
    if #rows == 0 then
        local label=self.filter == "updates" and "没有需要更新的插件\n可在上方切换到全部插件，手动重装或降级。"
            or self.filter == "missing" and "没有未安装的插件\n可在上方切换到全部插件。"
            or "PC 目录中没有插件\n请检查服务器的插件源目录并刷新。"
        items[#items+1]={text=label,bidi_wrap_func=function() return label end,dim=true,select_enabled=false}
    end
    local title=self.catalog.filters[self.filter] .. " · " .. #rows .. "/" .. #(self.plugins or {}) .. " 项"
    local subtitle=self.settings:readSetting("server","服务器未设置")
    if self.list_menu then
        local menu=self.list_menu
        local page,index=self.catalog.restorePosition(items,4,reset_position and 1 or menu.page,
            not reset_position and self.list_selected_id or nil,not reset_position and menu.itemnumber or 1)
        menu.page=page; menu.itemnumber=index; menu.title=title; menu.subtitle=subtitle
        menu:switchItemTable(title,items,-1,nil,subtitle)
        if reset_position then self.list_selected_id=nil end
        return
    end
    self.list_selected_id=nil
    self.list_menu=PluginMenu:new{title=title,
        subtitle=subtitle,item_table=items,fullscreen=true,
        single_line=false,multilines_forced=true,items_per_page=4,items_font_size=20,
        title_bar_left_icon="appbar.menu",onLeftButtonTap=function() self:showListOptions() end,
        close_callback=function() UIManager:close(self.list_menu); self.list_menu=nil end}
    UIManager:show(self.list_menu)
end
function PluginSync:download(plugin)
    if self:requireRestart() then return end
    if self.pending then return self:confirmInstall() end
    NetworkMgr:runWhenConnected(function()
        self:busyWork("准备下载插件…",function(progress)
            self.installer.check(plugin.id,self.fsutil,self.self_id)
            local target=self:targetFor(plugin.id)
            self.fsutil.removeTree(self.temp); self.fsutil.mkdir(self.temp)
            local ok,result=pcall(function()
                local version=self:request("/api/plugins/" .. plugin.id .. "/download",self.temp .. "/package.zip",function(bytes,total)
                    progress("下载插件", "已下载 " .. sizeText(bytes),bytes,total,total ~= nil)
                end)
                local stage=self.temp .. "/files"
                self.fsutil.mkdir(stage)
                progress("校验并解包","正在检查下载文件…",nil,nil,true)
                local files=self.archive.extract(self.temp .. "/package.zip",plugin.id,stage,self.fsutil,function(name,bytes,total)
                    progress("校验并解包",name,bytes,total)
                end)
                return {id=plugin.id,version=version,target=target,stage=stage,files=files,is_self=self:isSelfPlugin(plugin.id)}
            end)
            if not ok then
                local cleaned,cleanup_err=pcall(self.fsutil.removeTree,self.temp)
                error(tostring(result) .. (not cleaned and "\n临时文件清理失败：" .. tostring(cleanup_err) or ""))
            end
            return result
        end,function(pending)
            self.pending=pending; self:refreshHome(); self:confirmInstall()
        end,function(err)
            local ok,record_err=self:recordResult(plugin,"失败",err,"下载")
            assert(ok,record_err)
        end)
    end)
end
function PluginSync:confirmInstall()
    if self:requireRestart() then return end
    local pending=self.pending
    if not pending then return self:info("没有待安装的插件。") end
    local checked,space=pcall(self.installer.spaceInfo,pending,self.fsutil)
    local space_text
    if checked then
        space_text=string.format("\n空间预估：需要 %.2f MiB / 可用 %.2f MiB",space.required/1024/1024,space.available/1024/1024)
        if space.available < space.required then space_text=space_text .. "\n空间不足，请先清理设备空间。" end
    else space_text="\n空间检查失败，安装前必须重试检查：\n" .. tostring(space) end
    UIManager:show(ConfirmBox:new{
        text="下载完成。是否安装？\n\n" .. pending.id .. "\n版本: " .. (pending.version or "未知") .. "\n目标: " .. pending.target .. "\n\n同名文件将被覆盖，本机多余文件保留。"
            .. space_text .. (pending.is_self and "\n\n这是 PluginSync 自更新，完成后需重启，才能继续使用插件同步。" or ""),
        ok_text="安装",cancel_text="取消并清理",
        cancel_callback=function()
            local ok,err=pcall(self.fsutil.removeTree,self.temp)
            if ok then self.pending=nil; self:refreshHome()
            else self:info("清理失败：" .. tostring(err)) end
        end,
        ok_callback=function()
            local copied=false
            self:busyWork("正在覆盖安装…",function(progress)
                self.installer.check(pending.id,self.fsutil,self.self_id)
                progress("安装插件","准备复制 " .. #pending.files .. " 个文件",0,#pending.files,true)
                local ok,err=pcall(self.installer.install,pending,self.fsutil,function(current,total,name,bytes)
                    progress("安装插件",current .. "/" .. total .. " · " .. name .. " · " .. sizeText(bytes),current,total,current == total)
                end)
                assert(ok,"安装未完成，临时文件已保留。可在菜单中重试；部分文件可能已覆盖。\n" .. tostring(err))
                if pending.is_self then self.restart_required=true end
                copied=true
                -- Once all files are copied, retries must not repeat installation.
                self.pending=nil
                local records=self.settings:readSetting("installed",{})
                records[pending.id]={version=pending.version,time=os.time()}
                self.settings:saveSetting("installed",records)
                self.fsutil.removeTree(self.temp)
                local recorded,record_err=self:recordResult(pending,"成功")
                assert(recorded,"插件文件已安装，但结果记录保存失败：" .. tostring(record_err))
            end,function()
                if pending.is_self then
                    if self.list_menu then UIManager:close(self.list_menu); self.list_menu=nil end
                    self:requireRestart()
                    return
                end
                if self.list_menu then self:showList() end
                UIManager:askForRestart("插件安装完成，临时文件已清理。是否重启 KOReader？")
            end,function(err)
                local ok,record_err=self:recordResult(pending,copied and "已安装，收尾失败" or "失败",err)
                assert(ok,record_err)
                if copied then return "插件文件已安装，但结果记录或临时文件清理失败；请重启 KOReader。\n" .. tostring(err) end
            end)
        end,
    })
end
function PluginSync:homeItems()
    local items={
        {text="当前版本：" .. self.current_version,enabled=false},
        {text="服务器：" .. self.settings:readSetting("server","未设置（点击设置）"),callback=function() self:edit("server","PC 地址，如 http://192.168.1.100:3000") end},
        {text="搜索局域网服务器",callback=function() self:searchServers() end},
        {text="设置访问 Token（可选）",callback=function() self:edit("token","访问 Token（留空禁用）") end},
        {text="测试连接",callback=function()
            NetworkMgr:runWhenConnected(function()
                self:busyWork("正在测试连接…",function()
                    local value=self:request("/api/health")
                    assert(value.ok and value.service == "koreader-plugin-sync","服务类型不正确")
                end,function() self:info("连接成功。") end)
            end)
        end},
        {text="获取 PC 插件列表（默认需要更新）",callback=function() self:fetch(true) end},
        {text="安装结果记录",callback=function() self:showHistory() end},
    }
    if self.pending and not self.restart_required then
        items[#items+1]={text="继续安装 / 重试安装",callback=function() self:confirmInstall() end}
    end
    return items
end
function PluginSync:refreshHome()
    if self.home_menu then
        self.home_menu:switchItemTable("PluginSync / 插件同步",self:homeItems())
    end
end
function PluginSync:showHome()
    if self:requireRestart() then return end
    if self.home_menu then return end
    local menu
    menu=PluginMenu:new{title="PluginSync / 插件同步",item_table=self:homeItems(),fullscreen=true,
        close_callback=function()
            UIManager:close(menu)
            if self.home_menu == menu then self.home_menu=nil end
        end}
    self.home_menu=menu
    UIManager:show(menu)
end
function PluginSync:addToMainMenu(menu_items)
    menu_items.pluginsync={text="PluginSync / 插件同步",sorting_hint="more_tools",
        callback=function()
            -- Open after the main tools menu finishes closing.
            UIManager:nextTick(function() self:showHome() end)
        end}
end
return PluginSync
