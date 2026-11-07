-- Keep complete banks at their planned machine rate; only the last bank
-- receives the fractional remainder. No additional input/output flow is created.
local M={}
local capacity=require('capacity')
function M.counts(recipe,total,settings,previous_groups,solid_only)
 if #(recipe.products or {})~=1 then return end
 local incoming,outgoing={},0
 local fractional=tonumber((recipe.factory or {}).count) or total;if fractional<=0 then return end
 for _,p in ipairs(recipe.ingredients or {}) do
  if p.type~='fluid' then
   incoming[#incoming+1]=capacity.flow(p,recipe)/fractional
  elseif not solid_only then
   return
  end
 end
 for _,p in ipairs(recipe.products or {}) do if p.type=='fluid' then return end;outgoing=outgoing+capacity.flow(p,recipe)/fractional end
 local inc,out=capacity.belt(settings.belt_in),capacity.belt(settings.belt_out)
 local function fits(n)
  for i,rate in ipairs(incoming) do local share=1
   if #incoming>=3 and (i%2==0 or incoming[i+1]) then share=.5 end
   if rate*n>inc*share+1e-8 then return false end
   if n>1 and #incoming==2 and rate*math.ceil(n/2)>inc/2+1e-8 then return false end
  end
  if outgoing*n>out*(recipe.parallel_outputs and 2 or 1)+1e-8 then return false end
  if n>1 and (#incoming<=2 or solid_only) and outgoing*math.ceil(n/2)>out/(recipe.parallel_outputs and 1 or 2)+1e-8 then return false end
  return true
 end
 if not fits(1) then return end
 local lo,hi=1,total
 while lo<hi do local mid=math.ceil((lo+hi)/2);if fits(mid) then lo=mid else hi=mid-1 end end
 local result={};local remaining=total
 while remaining>0 do local n=math.min(lo,remaining);result[#result+1]=n;remaining=remaining-n end
 if #result>(previous_groups or total) then return end
 return result
end
function M.ratios(recipe,counts,settings)
 local total=0;for _,n in ipairs(counts) do total=total+n end
 local fractional=tonumber((recipe.factory or {}).count) or total
 local result={};local remaining=fractional;local safe=fractional>0
 for i,n in ipairs(counts) do
  local active=math.min(n,remaining);remaining=math.max(0,remaining-active)
  result[i]=fractional>0 and active/fractional or n/total
  local sub={base_time=1,factory={count=n},ingredients={},products={},parallel_outputs=recipe.parallel_outputs}
  for _,field in ipairs({'ingredients','products'}) do for _,p in ipairs(recipe[field] or {}) do
   sub[field][#sub[field]+1]={name=p.name,type=p.type,count=capacity.flow(p,recipe)*result[i]}
  end end
  local groups=capacity.split(sub,settings,n);if groups>1 then safe=false end
 end
 if remaining>1e-8 then safe=false end
 if not safe then for i,n in ipairs(counts) do result[i]=n/total end end
 return result
end
return M
