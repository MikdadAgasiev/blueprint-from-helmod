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
 return result
end
function M.done(mode,first_valid,index)
 return mode~='thorough' and first_valid~=nil and index>=first_valid
end
return M
