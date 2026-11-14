local socket = require("socket")
local json = require("json")
local bit = require("bit")
local M={port=3001,duration=4}
local function ipv4(ip)
    if type(ip) ~= "string" then return false end
    local a,b,c,d=ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    return a > 0 and a < 224 and b <= 255 and c <= 255 and d <= 255
end
function M.broadcast(ip,mask)
    if not ipv4(ip) or type(mask) ~= "string" then return end
    local a,b,c,d=mask:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return end
    local masks={tonumber(a),tonumber(b),tonumber(c),tonumber(d)}
    local value=0
    for _,part in ipairs(masks) do if part > 255 then return end; value=value*256+part end
    local inverse=4294967295-value
    if inverse <= 1 or inverse == 4294967295 or bit.band(inverse,inverse+1) ~= 0 then return end
    local result={}; local index=1
    for part in ip:gmatch("%d+") do
        result[index]=tostring(bit.bor(tonumber(part),255-masks[index])); index=index+1
    end
    return table.concat(result,".")
end
function M.interfaceAddresses(interface)
    -- Optional POSIX path: absence must not disable the portable UDP search.
    local ok,ffi=pcall(require,"ffi")
    if not ok or ffi.os == "Windows" or not pcall(require,"ffi/posix_h") then return {} end
    local ok_list,list=pcall(ffi.new,"struct ifaddrs *[1]")
    if not ok_list then return {} end
    local called,status=pcall(function() return ffi.C.getifaddrs(list) end)
    if not called or status ~= 0 then return {} end
    local success,result=pcall(function()
        local addresses={}
        local function host(addr)
            local text=ffi.new("char[?]",ffi.C.NI_MAXHOST)
            if ffi.C.getnameinfo(addr,ffi.sizeof("struct sockaddr_in"),text,ffi.C.NI_MAXHOST,
                nil,0,ffi.C.NI_NUMERICHOST) == 0 then return ffi.string(text) end
        end
        local item=list[0]
        while item ~= nil do
            if item.ifa_addr ~= nil and item.ifa_netmask ~= nil
                and item.ifa_addr.sa_family == ffi.C.AF_INET
                and bit.band(item.ifa_flags,3) == 3 and bit.band(item.ifa_flags,8) == 0
                and (not interface or ffi.string(item.ifa_name) == interface) then
                local ip,mask=host(item.ifa_addr),host(item.ifa_netmask)
                local address=M.broadcast(ip,mask)
                if address then addresses[#addresses+1]={ip=ip,mask=mask,broadcast=address} end
            end
            item=item.ifa_next
        end
        return addresses
    end)
    ffi.C.freeifaddrs(list[0])
    return success and result or {}
end
function M.interfaceBroadcasts(interface)
    local result={}
    for _,address in ipairs(M.interfaceAddresses(interface)) do result[#result+1]=address.broadcast end
    return result
end
function M.targets(options)
    options=options or {}
    local targets,seen={},{}
    local function add(ip)
        if type(ip) == "string" and (ip == "255.255.255.255" or ipv4(ip)) and not seen[ip] and #targets < 12 then
            targets[#targets+1]=ip; seen[ip]=true
        end
    end
    if options.target then add(options.target); return targets end
    local known=type(options.knownAddress) == "string" and
        (options.knownAddress:match("^http://(%d+%.%d+%.%d+%.%d+):%d+/?$")
        or options.knownAddress:match("^http://(%d+%.%d+%.%d+%.%d+)/?$"))
    add(known)
    for _,ip in ipairs(options.broadcasts or M.interfaceBroadcasts(options.interface)) do add(ip) end
    add("255.255.255.255")
    return targets
end
function M.parse(data,ip,nonce)
    if type(data) ~= "string" or #data > 1024 or not ipv4(ip) then return end
    local ok,reply=pcall(json.decode,data)
    if not ok or type(reply) ~= "table" or reply.type ~= "pluginsync-server"
        or reply.service ~= "koreader-plugin-sync" or reply.apiVersion ~= 1 or reply.nonce ~= nonce then return end
    if type(reply.port) ~= "number" or reply.port%1 ~= 0 or reply.port < 1 or reply.port > 65535 then return end
    local name=type(reply.name) == "string" and reply.name:gsub("[%z\1-\31\127]",""):sub(1,160) or "PC"
    if name == "" then name="PC" end
    -- Use the UDP sender IP, never an advertised URL or address.
    return {name=name,address="http://" .. ip .. ":" .. reply.port,authRequired=reply.authRequired == true}
end
function M.search(progress, options)
    options=options or {}
    assert(type(socket.udp4 or socket.udp) == "function","当前 KOReader 不支持 UDP 搜索，请手动设置地址。")
    local udp=assert((socket.udp4 or socket.udp)())
    local stats={sent=0,received=0,rejected=0,errors={},targets=M.targets(options)}
    local ok,result=pcall(function()
        assert(udp:setsockname("*",0))
        assert(udp:setoption("broadcast",true))
        assert(udp:settimeout(0.2))
        local nonce=string.format("%.6f-%d",socket.gettime(),math.random(1,1000000000))
        local request=json.encode{type="pluginsync-discover",apiVersion=1,nonce=nonce}
        local start=socket.gettime()
        local duration=options.duration or M.duration
        local next_send=0
        local found,seen={},{}
        while socket.gettime()-start < duration do
            local elapsed=socket.gettime()-start
            if elapsed >= next_send then
                for _,target in ipairs(stats.targets) do
                    local sent,err=udp:sendto(request,target,options.port or M.port)
                    if sent then stats.sent=stats.sent+1
                    else stats.errors[target]=tostring(err) end
                end
                if stats.sent == 0 then
                    local errors={}
                    for target,err in pairs(stats.errors) do errors[#errors+1]=target .. ": " .. err end
                    error("所有局域网搜索目标发送失败，请检查 Wi-Fi 和路由。\n" .. table.concat(errors,"\n"))
                end
                next_send=elapsed+1.3
            end
            local data,ip=udp:receivefrom(1024)
            if data then
                stats.received=stats.received+1
                local server=M.parse(data,ip,nonce)
                if server and not seen[server.address] and #found < 32 then
                    found[#found+1]=server; seen[server.address]=true
                end
                if not server then stats.rejected=stats.rejected+1 end
            elseif ip ~= "timeout" then
                -- ICMP errors from an unavailable directed target need not stop other probes.
                stats.errors.receive=tostring(ip)
            end
            if progress then progress(math.min(duration,socket.gettime()-start),duration,#found) end
        end
        table.sort(found,function(a,b)
            if a.name == b.name then return a.address < b.address end
            return a.name < b.name
        end)
        return found
    end)
    udp:close()
    assert(ok,result)
    return result,stats
end
return M
