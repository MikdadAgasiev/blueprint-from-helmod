-- Prefer an actual consumer over a recirculation loop. Ordinary splitter
-- fairness can otherwise impose a per-outlet cap even with spare input flow.
local M={}
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
function M.priorities(template)
 local nodes,cells,outputs={},{},{}
 for _,p in ipairs(template.outputs) do outputs[key(p.x,p.y)]=true end
 for i,e in ipairs(template.entities) do
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;local d=e.direction or 0
  if d%8==4 then w,h=h,w end
  local n={entity=e,kind=p.type,d=d,cells={},edges={}};nodes[i]=n
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  for dx=0,w-1 do for dy=0,h-1 do local c={x=x+dx,y=y+dy};cells[key(c.x,c.y)]=i;n.cells[#n.cells+1]=c;n.output=n.output or outputs[key(c.x,c.y)] end end
 end
 local function next_node(n,c)
  local v=vectors[n.d]
  if n.kind=='underground-belt' and n.entity.type=='input' then
   for distance=1,prototypes.entity[n.entity.name].max_underground_distance do
    local id=cells[key(c.x+distance*v[1],c.y+distance*v[2])];local other=id and nodes[id]
    if other and other.kind=='underground-belt' and other.entity.name==n.entity.name and other.d%8==n.d%8 then
     if other.d==n.d and other.entity.type=='output' then return id end;return
    end
   end
  else return cells[key(c.x+v[1],c.y+v[2])] end
 end
 for i,n in ipairs(nodes) do for _,c in ipairs(n.cells) do local id=next_node(n,c);if id and id~=i then n.edges[id]=true end end end
 local function exported(id,seen)
  if not id or seen[id] then return false end;seen[id]=true
  local n=nodes[id];if n.output then return true end
  for other in pairs(n.edges) do if exported(other,seen) then return true end end
  return false
 end
 local function reaches(id,target,seen)
  if id==target then return true end
  if not id or seen[id] then return false end;seen[id]=true
  for other in pairs(nodes[id].edges) do if reaches(other,target,seen) then return true end end
  return false
 end
 local result={}
 for i,n in ipairs(nodes) do if n.kind=='splitter' and not n.entity.filter then
  local a,b=n.cells[1],n.cells[2];local ai,bi=next_node(n,a),next_node(n,b)
  local ac,bc=reaches(ai,i,{}),reaches(bi,i,{})
  if ac~=bc and exported(ac and bi or ai,{}) then
   local c=ac and b or a;local v=vectors[n.d]
   local left=(c.x-n.entity.position.x+.5)*v[2]-(c.y-n.entity.position.y+.5)*v[1]>0
   result[i]=left and 'left' or 'right'
  end
 end end
 return result
end
return M
