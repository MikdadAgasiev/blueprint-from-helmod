-- Preserve the first collinear mouth seen by every existing input. Complete
-- non-overlapping pairs may follow each other; opposite/overlapping pairs may not.
local M={}
function M.safe(cell,x,y,dx,dy,length,d,name,reach)
 local mouths
 for i=-reach,length+reach do
  local nd,kind,tier=cell(x+dx*i,y+dy*i)
  if tier==name and (kind=='ug_in' or kind=='ug_out') and nd~=nil and nd%8==d%8 then
   if i>=0 and i<=length then return false end
   mouths=mouths or {};mouths[i]={d=nd,kind=kind}
  end
 end
 if not mouths then return true end
 for i,m in pairs(mouths) do if m.kind=='ug_in' then
  local sign=m.d==d and 1 or -1
  for step=1,reach do local j=i+sign*step
   if j==0 or j==length then return false end
   if mouths[j] then break end
  end
 end end
 return true
end

-- Nearest collinear mouths, with original input order breaking distance ties.
-- Grouping by tier/axis/line avoids comparing unrelated tunnels quadratically.
function M.issues(lists,first_only)
 local tiers,groups={},{},{}
 local index=0;local properties={}
 for _,entities in ipairs(lists) do for _,e in ipairs(entities) do
  local p=properties[e.name]
  if not p then
   local proto=prototypes.entity[e.name];p={type=proto.type}
   if p.type=='underground-belt' then p.max_underground_distance=proto.max_underground_distance end
   properties[e.name]=p
  end
  if p.type=='underground-belt' then
   index=index+1
   local axis=(e.direction or 0)%8
   local line=axis==0 and e.position.x or e.position.y
   local along=axis==0 and e.position.y or e.position.x
   tiers[e.name]=tiers[e.name] or {};local tier=tiers[e.name]
   tier[axis]=tier[axis] or {};local lines=tier[axis]
   local group=lines[line]
   if not group then group={reach=p.max_underground_distance};lines[line]=group;groups[#groups+1]=group end
   group[#group+1]={entity=e,coordinate=along,index=index}
  end
 end end
 local failures=0
 for _,group in ipairs(groups) do
  table.sort(group,function(a,b)if a.coordinate~=b.coordinate then return a.coordinate<b.coordinate end;return a.index<b.index end)
  local positions={}
  for _,entry in ipairs(group) do
   local last=positions[#positions]
   if not last or last.coordinate~=entry.coordinate then positions[#positions+1]=entry end
   entry.position=#positions
  end
  for _,entry in ipairs(group) do
   local e=entry.entity;local d=e.direction or 0
   local sign=(d==4 or d==8) and 1 or -1
   if e.type=='output' then sign=-sign end
   local neighbor=positions[entry.position+sign]
   local other=neighbor and neighbor.entity
   if not other or (other.direction or 0)~=d or other.type==e.type or math.abs(neighbor.coordinate-entry.coordinate)>group.reach then
    failures=failures+1;if first_only then return failures end
   end
  end
 end
 return failures
end
return M
