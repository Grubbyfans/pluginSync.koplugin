-- Bounded fallback discovery over the HTTP port when Wi-Fi blocks UDP broadcast.
local socket=require("socket")
local M={}
local function number(ip)
    if type(ip) ~= "string" then return end
    local a,b,c,d=ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return end
    a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    if a < 1 or a >= 224 or b > 255 or c > 255 or d > 255 then return end
    return ((a*256+b)*256+c)*256+d
end
local function address(n)
    return string.format("%d.%d.%d.%d",math.floor(n/16777216),math.floor(n/65536)%256,math.floor(n/256)%256,n%256)
end
function M.hosts(discovery,interfaces)
    local hosts,seen={},{}
    for _,entry in ipairs(interfaces) do
        local ip=number(entry.ip)
        local broadcast=number(discovery.broadcast(entry.ip,entry.mask))
        if ip and broadcast then
            local mask=entry.mask
            local value=0
            for part in mask:gmatch("%d+") do value=value*256+tonumber(part) end
            local network=broadcast-(4294967295-value)
            -- Larger networks: limit probing to the device's local /24 slice.
            local first=math.max(network+1,math.floor(ip/256)*256+1)
            local last=math.min(broadcast-1,math.floor(ip/256)*256+254)
            for n=first,last do
                if n ~= ip and not seen[n] and #hosts < 254 then hosts[#hosts+1]=address(n); seen[n]=true end
            end
        end
    end
    return hosts
end
function M.search(discovery,api,progress,options)
    options=options or {}
    local interfaces=options.interfaces or discovery.interfaceAddresses(options.interface)
    local hosts=M.hosts(discovery,interfaces)
    local stats={tested=0,open=0,verified=0,hosts=#hosts}
    if #hosts == 0 then stats.reason="无法读取设备网段，HTTP 备用搜索未运行"; return {},stats end
    local ports={3000}
    local saved_port=type(options.knownAddress) == "string" and tonumber(options.knownAddress:match(":(%d+)/?$"))
    if saved_port and saved_port ~= 3000 and saved_port > 0 and saved_port <= 65535 then ports[#ports+1]=saved_port end
    local jobs={}
    for _,ip in ipairs(hosts) do for _,port in ipairs(ports) do jobs[#jobs+1]={ip=ip,port=port} end end
    local pending,opened,all={}, {},{}
    local start=socket.gettime()
    local deadline=start+(options.duration or 7)
    local scan_deadline=start+math.min(4,options.duration or 7)
    local next_job=1
    local function close(peer)
        if peer.socket then pcall(peer.socket.close,peer.socket); all[peer.socket]=nil end
    end
    local ok,result=pcall(function()
        while socket.gettime() < scan_deadline and (next_job <= #jobs or #pending > 0) and #opened < 8 do
            while #pending < 24 and next_job <= #jobs do
                local job=jobs[next_job]; next_job=next_job+1
                local tcp=assert(socket.tcp())
                all[tcp]=true
                assert(tcp:settimeout(0))
                local peer={socket=tcp,ip=job.ip,port=job.port,start=socket.gettime()}
                local connected,err=tcp:connect(job.ip,job.port)
                stats.tested=stats.tested+1
                if connected then opened[#opened+1]=peer; close(peer)
                elseif err == "timeout" or err == "Operation already in progress" then pending[#pending+1]=peer
                else close(peer) end
                if #opened >= 8 then break end
            end
            local writable={}
            for _,peer in ipairs(pending) do writable[#writable+1]=peer.socket end
            if #writable > 0 then
                local _,ready=socket.select({},writable,0.04)
                local selected={}; for _,tcp in ipairs(ready or {}) do selected[tcp]=true end
                local keep={}
                for _,peer in ipairs(pending) do
                    if selected[peer.socket] then
                        local connected,ip=pcall(function() return peer.socket:getpeername() end)
                        if connected and ip and #opened < 8 then opened[#opened+1]=peer end
                        close(peer)
                    elseif socket.gettime()-peer.start >= 0.2 then close(peer)
                    else keep[#keep+1]=peer end
                end
                pending=keep
            end
            if progress then progress(stats.tested,#jobs,#opened) end
        end
        for _,peer in ipairs(pending) do close(peer) end
        local found={}
        stats.open=#opened
        for _,peer in ipairs(opened) do
            local remaining=deadline-socket.gettime()
            if remaining <= 0 then break end
            local url="http://" .. peer.ip .. ":" .. peer.port
            -- Never send the user's Token to unverified LAN hosts.
            local verified,reply=pcall(api.request,url,nil,"/api/discovery",nil,nil,
                {block_timeout=math.min(0.5,remaining),total_timeout=math.min(0.7,remaining),max_bytes=4096})
            if verified and type(reply) == "table" and reply.service == "koreader-plugin-sync"
                and reply.apiVersion == 1 and reply.discoveryVersion == 1 then
                local name=type(reply.name) == "string" and reply.name:gsub("[%z\1-\31\127]",""):sub(1,160) or "PC"
                found[#found+1]={name=name,address=url,authRequired=reply.authRequired == true}
            end
        end
        stats.verified=#found
        return found
    end)
    for tcp in pairs(all) do pcall(tcp.close,tcp) end
    assert(ok,result)
    return result,stats
end
return M
