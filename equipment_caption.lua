-- Characteristics are prototype values, not promised recipe throughput.
local M={}
local pair=require('pipe_pair')
function M.make(name)
 local p=prototypes.entity[name]
 if not p then return {'entity-name.'..name} end
 local item
 for _,v in pairs(p.items_to_place_this or {}) do
  local candidate=prototypes.item[v.name]
  if candidate and not candidate.hidden and candidate.place_result and candidate.place_result.name==name then item=candidate;break end
 end
 local caption={'',item and ('[item='..item.name..'] ') or ('[entity='..name..'] '),item and item.localised_name or p.localised_name}
 local detail
 if p.belt_speed then detail={'bfh.items-per-second',string.format('%g',p.belt_speed*480)}
 elseif p.type=='inserter' then detail={'bfh.rotation-per-second',string.format('%.2f',p.get_inserter_rotation_speed('normal')*60)}
 elseif p.type=='electric-pole' then detail={'bfh.pole-characteristics',string.format('%g',p.get_supply_area_distance('normal')*2),string.format('%g',p.get_max_wire_distance('normal'))}
 elseif p.type=='pipe' then
  local ug,reach=pair.resolve(name)
  detail=ug and {'bfh.pipe-characteristics',tostring(reach)} or {'bfh.pipe-surface-only'}
 end
 if detail then caption[#caption+1]=' - ';caption[#caption+1]=detail end
 return caption
end
return M
