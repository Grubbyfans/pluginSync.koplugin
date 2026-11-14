local M = {}
M.filters={updates="需要更新",all="全部",missing="未安装"}
M.sorts={priority="更新优先",name="名称升序",name_desc="名称降序"}
local priority={ ["PC 版本较新"]=1,["未安装"]=2,["本机目录冲突"]=3,
    ["本机版本未知"]=4,["PC 版本未知"]=4,["无法比较"]=4,["PC 版本较旧"]=5,["版本一致"]=6 }
function M.rows(plugins, lookup, version, filter, sort)
    local rows={}
    for _,plugin in ipairs(plugins or {}) do
        local ok,target,installed,local_version,source=pcall(lookup,plugin)
        local status=ok and version.status(plugin.version,local_version,installed) or "本机目录冲突"
        if filter == "all" or (filter == "updates" and status == "PC 版本较新")
            or (filter == "missing" and ok and not installed) then
            rows[#rows+1]={plugin=plugin,ok=ok,target=target,installed=installed,version=local_version,status=status,source=source}
        end
    end
    table.sort(rows,function(a,b)
        if sort == "priority" and priority[a.status] ~= priority[b.status] then return priority[a.status] < priority[b.status] end
        local x,y=a.plugin.name:lower(),b.plugin.name:lower()
        if x == y then return a.plugin.id < b.plugin.id end
        if sort == "name_desc" then return x > y end
        return x < y
    end)
    return rows
end
function M.restorePosition(items,perpage,page,selected_id,old_index)
    page=math.max(1,math.min(page or 1,math.max(1,math.ceil(#items/perpage))))
    local first,last=(page-1)*perpage+1,math.min(page*perpage,#items)
    local index=math.max(first,math.min(old_index or first,last))
    if selected_id then
        for i=first,last do if items[i].plugin_id == selected_id then index=i; break end end
    end
    return page,index
end
return M
