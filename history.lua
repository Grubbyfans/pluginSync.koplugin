local M={limit=50}
function M.append(settings, entry)
    local old=settings:readSetting("history",{})
    local entries={entry}
    for i=1,math.min(#old,M.limit-1) do entries[#entries+1]=old[i] end
    settings:saveSetting("history",entries)
    local ok,err=pcall(settings.flush,settings)
    if not ok then settings:saveSetting("history",old); error(err) end
end
return M
