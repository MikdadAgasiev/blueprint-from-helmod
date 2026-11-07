-- Before routing, contacts between independent templates have no planned intent.
local M={}
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
function M.between(entities,blocks)
 local cells,nodes={},{}
 for bi,b in ipairs(blocks) do for i=b.entity_first,b.entity_last do
  local e=entities[i];local p=prototypes.entity[e.name]
  if p and (p.type=='transport-belt' or p.type=='underground-belt' or p.type=='splitter') then
   local w,h=p.tile_width,p.tile_height;local d=e.direction or 0;if d==4 or d==12 then w,h=h,w end
   local n={owner=bi,d=d,kind=p.type,side=e.type};nodes[#nodes+1]=n
   n.cells={};local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
   for dx=0,w-1 do for dy=0,h-1 do local c={x=x+dx,y=y+dy};n.cells[#n.cells+1]=c;cells[key(c.x,c.y)]=n end end
  end
 end end
 local issues={}
 for _,n in ipairs(nodes) do if not(n.kind=='underground-belt' and n.side~='output') then
  local v=vectors[n.d]
  for _,c in ipairs(n.cells) do local q=cells[key(c.x+v[1],c.y+v[2])]
   if q and q.owner~=n.owner and q.d~=(n.d+8)%16 and not(q.kind=='underground-belt' and q.side=='output') and (q.kind~='splitter' or q.d==n.d) then
    local planned=false
    for _,port in ipairs(blocks[q.owner].inputs or {}) do
      if port.array_local and port.array_source_owner==n.owner and n.d==(port.direction or 8) and port.x==c.x+v[1] and port.y==c.y+v[2] then planned=true;break end
    end
    for _,port in ipairs(blocks[n.owner].array_output_contacts or {}) do
      if port.owner==q.owner and n.d==(port.direction or 8) and port.x==c.x+v[1] and port.y==c.y+v[2] then planned=true;break end
    end
    if not planned then issues[#issues+1]='Unplanned template contact at '..key(c.x,c.y)..' -> '..key(c.x+v[1],c.y+v[2]) end
   end
  end
 end end
 return issues
end
return M
