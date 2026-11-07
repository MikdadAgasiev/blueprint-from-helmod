-- Combine identical furnace requests before rounding and belt splitting.
-- Keep assembly groups separate: rounding surplus must not bypass their dedicated supplies.
local M={}
local capacity=require('capacity')
local work=require('generation_work')
local beacons=require('beacons')
local function signature(value)
 if type(value)~='table' then return type(value)..':'..tostring(value) end
 local keys={};for k in pairs(value) do keys[#keys+1]=k end
 table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
 local out={'{'};for _,k in ipairs(keys) do out[#out+1]=signature(k)..'='..signature(value[k])..';' end
 out[#out+1]='}';return table.concat(out)
end
local function compatible(a,b)
 local machine=prototypes and prototypes.entity and prototypes.entity[(a.factory or {}).name or '']
 if not machine or machine.type~='furnace' then return false end
 if a.name~=b.name or a.class~=b.class or (a.quality or 'normal')~=(b.quality or 'normal') or a.base_time~=b.base_time or beacons.has(a) or beacons.has(b) then return false end
 local af,bf=work.copy(a.factory or {}),work.copy(b.factory or {})
 local ac,bc=af.count,bf.count;af.count=nil;bf.count=nil;af.quality=af.quality or 'normal';bf.quality=bf.quality or 'normal'
 if not ac or not bc or ac<=0 or bc<=0 or signature(af)~=signature(bf) then return false end
 for _,side in ipairs({'ingredients','products'}) do
  if #(a[side] or {})~=#(b[side] or {}) then return false end
  for i,x in ipairs(a[side] or {}) do local y=b[side][i]
   if x.type=='fluid' or y.type=='fluid' then return false end
   local xx,yy=work.copy(x),work.copy(y);xx.count=nil;yy.count=nil
   if signature(xx)~=signature(yy) or math.abs(capacity.flow(x,a)/ac-capacity.flow(y,b)/bc)>1e-8 then return false end
  end
 end
 return true
end
-- Spatial grouping never combines recipe quantities or rounds machine counts again.
function M.spatial_key(r)
 if beacons.has(r) then return end
 for _,side in ipairs({'ingredients','products'}) do for _,p in ipairs(r[side] or {}) do if p.type=='fluid' then return end end end
 local f=work.copy(r.factory or {})
 return signature({name=r.name,class=r.class,quality=r.quality or 'normal',base_time=r.base_time,factory=f})
end
function M.combine(recipes)
 local result={}
 for _,r in ipairs(recipes) do
  local found
  for _,q in ipairs(result) do if compatible(q,r) then found=q;break end end
  if found then
   for _,side in ipairs({'ingredients','products'}) do for i,p in ipairs(found[side] or {}) do
    p.count=capacity.flow(p,found)*(tonumber(found.base_time) or 1)+capacity.flow(r[side][i],r)*(tonumber(found.base_time) or 1)
   end end
   found.count=(found.count or 0)+(r.count or 0);found.factory.count=found.factory.count+r.factory.count
  else result[#result+1]=work.copy(r) end
 end
 return result
end
return M
