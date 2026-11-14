local M={}
function M.explain(err)
    local detail=tostring(err)
    local lower=detail:lower()
    local message
    if lower:find("401",1,true) then message="访问被拒绝：请检查 PC 和设备的 Token 是否一致。"
    elseif lower:find("404",1,true) then message="PC 上找不到该插件：请刷新列表并检查插件目录。"
    elseif lower:find("500",1,true) then message="PC 打包失败：请检查源插件结构、文件大小及服务端输出。"
    elseif lower:find("timeout",1,true) or detail:find("超时",1,true) then message="连接或下载超时：检查服务器地址、同一局域网、防火墙和 PC 服务是否运行。"
    elseif lower:find("refused",1,true) then message="连接被拒绝：请启动 PC 服务并检查端口。"
    elseif lower:find("host",1,true) or lower:find("unreachable",1,true) then message="无法找到或访问服务器：请检查 IP 地址和网络连接。"
    elseif lower:find("no space",1,true) or lower:find("disk full",1,true) or detail:find("空间不足",1,true) then message="设备存储空间不足：清理空间后重新尝试。"
    elseif detail:find("无法检查安装空间",1,true) then message="无法取得设备可用空间，尚未覆盖文件。请检查设备挂载状态和 KOReader 的磁盘空间接口。"
    elseif lower:find("permission",1,true) or lower:find("read-only",1,true) then message="没有写入权限或目录只读：请检查设备存储状态。"
    elseif detail:find("CRC",1,true) or detail:find("ZIP",1,true) or detail:find("长度",1,true) then message="下载包损坏或格式不支持：请重新下载；安装前校验失败不会覆盖本机插件。"
    elseif detail:find("目标冲突",1,true) or detail:find("符号链接",1,true) then message="安装路径存在文件、目录或链接冲突：请检查提示中的路径。"
    elseif lower:find("closed",1,true) or lower:find("reset",1,true) then message="连接中断：检查 PC 服务和 Wi-Fi 后重新下载。"
    else message="操作未完成，请根据下方具体错误检查后重试。" end
    return message .. "\n\n详细信息：\n" .. detail
end
return M
