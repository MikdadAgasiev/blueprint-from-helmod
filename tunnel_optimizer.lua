-- Remove only tunnels whose complete surface replacement is safe.
local M={}
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
function M.apply(entities,en,settings)
 local cells,danger={},{}
 local function node(e)
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;local d=e.direction or 0
  if d%8==4 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  local n={entity=e,kind=p.type,d=d,x=x,y=y}
  for xx=x,x+w-1 do for yy=y,y+h-1 do cells[key(xx,yy)]=n end end
  if p.type=='inserter' then
   if p.inserter_pickup_position and p.inserter_drop_position and not e.pickup_position and not e.drop_position then
    for _,pos in ipairs({p.inserter_pickup_position,p.inserter_drop_position}) do
     local px,py=pos.x or pos[1],pos.y or pos[2]
     for turn=1,d/4 do px,py=-py,px end
     danger[key(math.floor(e.position.x+px),math.floor(e.position.y+py))]=true
    end
   else for xx=x-3,x+3 do for yy=y-3,y+3 do danger[key(xx,yy)]=true end end end
  end
  return n
 end
 for _,e in ipairs(entities) do node(e) end
 local removed=0
 for i=1,#entities do local e=entities[i];local proto=prototypes.entity[e.name]
  if proto.type=='underground-belt' and e.type=='input' and (not e.quality or e.quality=='normal') then
   local d=e.direction or 0;local v=vectors[d];local x,y=math.floor(e.position.x),math.floor(e.position.y)
   local target,length
   for n=1,proto.max_underground_distance do local q=cells[key(x+v[1]*n,y+v[2]*n)]
    if q and q.kind=='underground-belt' and q.entity.name==e.name and q.d%8==d%8 then
     if q.d==d and q.entity.type=='output' then target,length=q,n end;break
    end
   end
   local belt
   for _,name in ipairs({settings.belt_in or 'transport-belt',settings.belt_out or 'transport-belt'}) do local p=prototypes.entity[name]
    if p and p.type=='transport-belt' and p.belt_speed==proto.belt_speed then belt=name;break end
   end
   local safe=target and belt and not e.wires and not target.entity.wires
   if safe then
    for step=1,length-1 do if cells[key(x+v[1]*step,y+v[2]*step)] then safe=false end end
    -- Removing a pair must not expose another same-tier collinear mouth.
    for step=-proto.max_underground_distance,length+proto.max_underground_distance do
     local q=cells[key(x+v[1]*step,y+v[2]*step)]
     if step~=0 and step~=length and q and q.kind=='underground-belt' and q.entity.name==e.name and q.d%8==d%8 then safe=false end
    end
    for step=0,length do local xx,yy=x+v[1]*step,y+v[2]*step
     if danger[key(xx,yy)] then safe=false end
     for _,a in pairs(vectors) do local q=cells[key(xx+a[1],yy+a[2])]
      local along=(q and ((q.x-x)*v[2]-(q.y-y)*v[1])==0)
      local in_span=q and along and (q.x-x)*v[1]+(q.y-y)*v[2]>=0 and (q.x-x)*v[1]+(q.y-y)*v[2]<=length
      if q and not in_span then
       if q.kind=='loader' or q.kind=='loader-1x1' then safe=false end
       local qv=vectors[q.d]
       local feeds=(q.kind=='transport-belt' or q.kind=='splitter' or q.kind=='underground-belt' and q.entity.type=='output') and qv and xx+a[1]+qv[1]==xx and yy+a[2]+qv[2]==yy
       if feeds and not(step==0 and a[1]==-v[1] and a[2]==-v[2]) then safe=false end
      end
     end
    end
   end
   if safe then
    e.name=belt;e.type=nil;target.entity.name=belt;target.entity.type=nil;node(e);node(target.entity)
    for step=1,length-1 do local b={entity_number=en,name=belt,position={x=x+v[1]*step+.5,y=y+v[2]*step+.5},direction=d}
     en=en+1;entities[#entities+1]=b;node(b)
    end
    removed=removed+1
   end
  end
 end
 return en,removed
end
return M
