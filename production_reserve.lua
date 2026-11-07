local M={}
local work=require('generation_work')
local resources=require('resources')
function M.percent(value)
 value=tonumber(value) or 0
 return (value==5 or value==10 or value==20) and value or 0
end
local function key(item)return (item.type or 'item')..'/'..resources.key(item.name,item.quality) end
function M.apply(recipes,value)
 local percent=M.percent(value);local out=work.copy(recipes)
 if percent==0 then return out end
 local consumers={}
 for i,r in ipairs(recipes) do for _,item in pairs(r.ingredients or {}) do
  local k=key(item);consumers[k]=consumers[k] or {};consumers[k][i]=true
 end end
 for i,r in ipairs(out) do
  local intermediate,has_products=true,false
  for _,item in pairs(r.products or {}) do
   has_products=true;local used=false
   for consumer in pairs(consumers[key(item)] or {}) do if consumer~=i then used=true;break end end
   if not used then intermediate=false;break end
  end
  -- Mixed terminal/intermediate coproducts stay unchanged: do not silently
  -- increase a final product or treat a recycling loop as external demand.
  if intermediate and has_products then
   local factor=1+percent/100
   r.factory=r.factory or {};r.factory.count=(tonumber(r.factory.count) or 1)*factor
   local per_craft=r.base_time and type(r.count)=='number'
   if type(r.count)=='number' then r.count=r.count*factor end
   for _,field in ipairs({'ingredients','products'}) do for _,item in pairs(r[field] or {}) do
    if type(item.count)=='number' then item.count=item.count*factor end
    if type(item.amount)=='number' and not per_craft then item.amount=item.amount*factor end
   end end
  end
 end
 return out
end
return M
