-- Immutable index of collinear underground-pipe segments.
local M={}
function M.build(tunnels)
 local index={vertical={},horizontal={}}
 local function add(lines,line,a,b)
  local list=lines[line] or {};lines[line]=list
  list[#list+1]={math.min(a,b),math.max(a,b)}
 end
 for _,t in ipairs(tunnels) do
  if t.x==t.xx then add(index.vertical,t.x,t.y,t.yy) end
  if t.y==t.yy then add(index.horizontal,t.y,t.x,t.xx) end
 end
 for _,lines in pairs(index) do for line,list in pairs(lines) do
  table.sort(list,function(a,b)if a[1]~=b[1] then return a[1]<b[1] end;return a[2]<b[2] end)
  local merged={}
  for _,interval in ipairs(list) do
   local last=merged[#merged]
   if last and interval[1]<=last[2] then last[2]=math.max(last[2],interval[2])
   else merged[#merged+1]={interval[1],interval[2]} end
  end
  lines[line]=merged
 end end
 return index
end
local function clear(list,a,b)
 if not list then return true end
 local low,high=math.min(a,b),math.max(a,b)
 local first,last=1,#list
 while first<=last do
  local middle=math.floor((first+last)/2)
  if list[middle][2]<low then first=middle+1 else last=middle-1 end
 end
 return not list[first] or list[first][1]>high
end
function M.clear(index,x,y,xx,yy)
 if x==xx and not clear(index.vertical[x],y,yy) then return false end
 if y==yy and not clear(index.horizontal[y],x,xx) then return false end
 return true
end
return M
