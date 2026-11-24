-- Bound ordinary layout search without weakening route validation.
local M={}
local base={{gap=0,compact=1.4,dense=true,align_ports=true},{gap=1,compact=1,dense=true,align_ports=true},{gap=0,compact=1,dense=true},{gap=0,compact=1.4,dense=true},{gap=1,compact=1,dense=true},{gap=2,compact=1,dense=true},{gap=1,compact=1.4,dense=true},{gap=2,compact=1.4,dense=true},{gap=1,compact=1},{gap=2,compact=1},{gap=2,compact=1.4},{gap=4,compact=1,dense=true},{gap=2},{gap=4},{gap=8},{gap=16},{}}
function M.options(alternative,mode,arrays)
 local result={}
 local function add(i,legacy,gap)
  local option={};for k,v in pairs(base[i]) do option[k]=v end
  if gap~=nil then option.gap=gap end
  if legacy then option.legacy=true end;result[#result+1]=option
 end
 if mode=='thorough' then
  if arrays then add(3,alternative,4);result[#result].arrays=true end
  add(3,alternative,2);result[#result].flow_aware=true
  if alternative then for _,i in ipairs({1,2,10,12}) do add(i) end end
  for i=1,#base do add(i,alternative) end
 elseif arrays then
  add(3,alternative,4);result[#result].arrays=true
  add(3,alternative,2);result[#result].flow_aware=true
  add(6);add(12,alternative,6);add(12,alternative);add(17,alternative)
 elseif alternative then
  -- Compare both production topologies early instead of exhausting one first.
  -- Unaligned dense placement leaves routing corridors flexible; port alignment
  -- is a challenger rather than a mandatory first pass.
  -- Try a merge-friendly dense candidate before the expensive alternative
  -- topology. The compact zero-gap and four-gap challengers still compete.
  add(3,true,2);result[#result].flow_aware=true;add(12,true,6);add(6);add(12,true);add(1);add(17,true)
 else
  for _,i in ipairs({3,6,12,1,10,17}) do add(i) end
 end
 if mode=='thorough' then while #result>21 do table.remove(result) end end
 for i,option in ipairs(result) do
  option.gap=0;option.arrays={pack=true,hierarchical=true,cluster_limit=({6,4,8})[(i-1)%3+1],approach=math.min(3,1+math.floor((i-1)/2))}
 end
 if mode~='thorough' then
  -- Try routing clearance if the first compact layout cannot carry every flow.
  table.insert(result,2,{gap=2,compact=1,dense=true,flow_aware=true})
 end
 return result
end
-- Recipe data exists before placement; layout port metadata does not.
function M.fluid_first(options,blocks,mode,distribution)
 if mode=='thorough' or not options[1] then return options end
 local has_fluid=false
 for _,block in ipairs(blocks) do
  for _,side in ipairs({'ingredients','products'}) do
   for _,item in ipairs((block.recipe_node or {})[side] or {}) do
    if item.type=='fluid' then has_fluid=true end
   end
  end
 end
 if not has_fluid then return options end
 local base=options[1]
 for _,option in ipairs(options) do if option.gap==2 and not option.arrays then base=option;break end end
 local first={};for k,v in pairs(base) do first[k]=v end
 first.fluids_first=true;first.inputs_first=nil
 local fallback={};for k,v in pairs(first) do fallback[k]=v end
 if distribution=='containers' then first.gap=2;fallback.gap=6 else fallback.gap=4 end
 local result={first,fallback};for _,option in ipairs(options) do result[#result+1]=option end
 return result
end
-- Shared pools add explicit producer-to-pool legs. Budget actual connections,
-- so adding logistics nodes does not leave the last consumers unattempted.
function M.route_budget(blocks,mode)
 if mode=='thorough' then return nil end
 local count=0
 for _,b in ipairs(blocks or {}) do for _,p in ipairs(b.inputs or {}) do if p.flow_edge then count=count+1 end end end
 return math.max(240000,math.min(720000,count*6000))
end
function M.done(mode,first_valid,index)
 return mode~='thorough' and first_valid~=nil and index>=first_valid
end
-- Compare the small, acyclic option records, including nested array settings.
-- Keep unknown fields significant so future routing options cannot be lost.
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not same(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
-- Run after caller-specific beacon/clearance adjustments. Preserve the first
-- candidate and its order; do not spend a placement pass on identical options.
function M.unique(options)
 local result={}
 for _,option in ipairs(options) do
  local duplicate=false
  for _,previous in ipairs(result) do
   if same(option,previous) then duplicate=true;break end
  end
  if not duplicate then result[#result+1]=option end
 end
 return result
end
return M
