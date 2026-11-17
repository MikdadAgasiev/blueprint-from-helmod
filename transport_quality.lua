-- Transport quality is independent of Helmod production equipment and recipes.
local M={}
local work=require('generation_work')
local kinds={['transport-belt']=true,['underground-belt']=true,splitter=true,
 ['loader-1x1']=true,loader=true,inserter=true}
function M.available(force)
 local names={}
 for name,p in pairs(prototypes.quality or {}) do
  -- Normal quality remains usable when the quality feature is disabled.
  if name=='normal' or (not p.hidden and force.is_quality_unlocked(name)) then names[#names+1]=name end
 end
 table.sort(names,function(a,b)
  local x,y=prototypes.quality[a].level,prototypes.quality[b].level
  if x~=y then return x<y end;return a<b
 end)
 return names
end
function M.caption(name)
 if name=='normal' then return {'bfh.quality-normal'} end
 return prototypes.quality[name].localised_name
end
function M.validate(quality,force)
 quality=quality or 'normal'
 if not (prototypes.quality or {})[quality] or (quality~='normal' and not force.is_quality_unlocked(quality)) then
  error({'bfh.transport-quality-unavailable',quality},0)
 end
 return quality
end
work.register('transport-quality',function(a,s)
 s.index=s.index or 1;s.result=s.result or {};s.checked=s.checked or {}
 while s.index<=#a.entities do
  if not work.consume(4) then return false end
  local entity=a.entities[s.index];local p=prototypes.entity[entity.name]
  if kinds[p.type] then
   if p.type=='inserter' and not s.checked[entity.name] then
    -- Allocation intentionally keeps its conservative normal-quality estimate.
    -- Reject unusual modded qualities that would make an inserter slower.
    for _,getter in ipairs({'get_inserter_rotation_speed','get_inserter_extension_speed'}) do
     if (p[getter](a.quality) or 0)<(p[getter]('normal') or 0) then
      error({'bfh.transport-quality-slower',entity.name,a.quality},0)
     end
    end
    s.checked[entity.name]=true
   end
   entity=work.copy(entity);entity.quality=a.quality
  end
  s.result[#s.result+1]=entity;s.index=s.index+1
 end
 return true,s.result
end)
function M.apply(entities,quality)
 if not quality or quality=='normal' then return entities end
 return work.operation('transport-quality',nil,{entities=entities,quality=quality})
end
return M
