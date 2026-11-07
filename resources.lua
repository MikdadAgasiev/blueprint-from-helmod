-- Routing identities are private; native APIs always receive separate name/quality.
local M={}
local separator=string.char(31)
function M.quality(value)
 if value~=nil and type(value)~='string' then return value.name or 'normal' end
 return value or 'normal'
end
function M.name(value)return value:match('^(.-)'..separator) or value end
function M.grade(value)return value:match(separator..'(.+)$') or 'normal' end
function M.key(name,quality)
 local q=M.quality(quality)
 if q=='normal' then return name end
 return M.name(name)..separator..q
end
function M.filter(key)return {name=M.name(key),quality=M.grade(key),comparator='='} end
function M.caption(key)
 local name=M.name(key);local p=prototypes.item[name];local text=p and p.localised_name or name
 local q=M.grade(key)
 if q=='normal' then return text end
 return {'bfh.resource-quality',text,prototypes.quality[q].localised_name}
end
function M.port(block,key)return block.product_outs and block.product_outs[key] or block.product_out end
function M.ports(block,key)
 local p=block.product_outs and block.product_outs[key]
 if p then return {p} end
 if block.output_ports then return block.output_ports end
 return block.product_out and {block.product_out} or {}
end
function M.decode(ports)
 for _,p in ipairs(ports or {}) do if p.type=='item' then p.quality=M.grade(p.name);p.name=M.name(p.name) end end
end
return M
