local M={}
local capacity=require('capacity')
-- Compare explicit Helmod flows only. Prototype per-craft amounts are not rates.
function M.summary(recipes)
 local totals={}
 for _,recipe in ipairs(recipes) do
  for _,field in ipairs({'ingredients','products'}) do
   for _,item in pairs(recipe[field] or {}) do
    local k=(item.type or 'item')..'/'..item.name
    local t=totals[k] or {name=item.name,type=item.type or 'item',produced=0,needed=0,known=true};totals[k]=t
    if field=='products' then t.has_producer=true end
    local explicit=capacity.explicit_flow(item,recipe)
    if not explicit then t.known=false else
     local value=capacity.flow(item,recipe)
     if field=='products' then t.produced=t.produced+value else t.needed=t.needed+value end
    end
   end
  end
 end
 local keys={};for k in pairs(totals) do keys[#keys+1]=k end;table.sort(keys)
 local report={deficits={},imports={},unknown={}}
 for _,k in ipairs(keys) do local t=totals[k]
  if not t.known then report.unknown[#report.unknown+1]=t
  elseif t.needed>t.produced+1e-8 then
   t.shortfall=t.needed-t.produced
   local list=t.has_producer and report.deficits or report.imports
   list[#list+1]=t
  end
 end
 return report
end
function M.rates(recipes)return M.summary(recipes).deficits end
return M
