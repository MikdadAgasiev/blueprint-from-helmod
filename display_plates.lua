local resources=require('resources')
local M={}
local plate='copper-display-small'
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
function M.available()
 return script.active_mods.DisplayPlatesForked~=nil and prototypes.entity[plate]~=nil
end
function M.add(entities,blocks,interface,settings,underground,report)
 if not M.available() then return 0,0 end
 local occupied,belts,ports,produced={},{},{},{}
 local serial=0
 local function occupy(e)
  local proto=prototypes.entity[e.name];local w,h=proto.tile_width,proto.tile_height
  if e.direction==4 or e.direction==12 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+0.001),math.floor(e.position.y-h/2+0.001)
  for dx=0,w-1 do for dy=0,h-1 do occupied[key(x+dx,y+dy)]=true end end
  if proto.type=='transport-belt' then belts[key(x,y)]=e end
 end
 for _,e in ipairs(entities) do serial=math.max(serial,e.entity_number or 0);occupy(e) end
 for _,b in ipairs(blocks) do for _,p in pairs((b.recipe_node or {}).products or {}) do
  if p.type~='fluid' then produced[p.name]=true end
 end end
 if interface then
  for _,p in ipairs(interface) do if p.type=='item' then
   ports[#ports+1]={x=p.x,y=p.y,name=p.name,dir=4,entry=p,block=blocks[p.block]}
  end end
 else
  for _,b in ipairs(blocks) do for _,p in ipairs(b.inputs or {}) do if not produced[p.ingredient] then
   local belt=belts[key(p.x,p.y)]
   ports[#ports+1]={x=p.x,y=p.y,name=p.ingredient,dir=p.direction or (belt and belt.direction) or 8,block=b}
  end end end
 end
 local function new(name,x,y,d,extra)
  local e={name=name,position={x=x+0.5,y=y+0.5},direction=d or 0}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
 end
 local function sign(p,x,y)
  return new(plate,x,y,0,{icon={type='item',name=resources.name(p.name),quality=resources.grade(p.name)},always_show=true,show_in_chart=false,text=resources.grade(p.name)=='normal' and '' or ('[quality='..resources.grade(p.name)..']')})
 end
 local function tunnels_safe(extra)
  local mouths={}
  for _,list in ipairs({entities,extra}) do for _,e in ipairs(list) do
   if prototypes.entity[e.name].type=='underground-belt' then mouths[#mouths+1]=e end
  end end
  for _,e in ipairs(mouths) do
   local d=e.direction or 0;local v=vectors[d];local sense=e.type=='output' and -1 or 1
   local closest,distance
   for _,other in ipairs(mouths) do if other~=e and other.name==e.name and (other.direction or 0)%8==d%8 then
    local dx,dy=other.position.x-e.position.x,other.position.y-e.position.y
    local along=(dx*v[1]+dy*v[2])*sense
    if dx*v[2]-dy*v[1]==0 and along>0 and (not distance or along<distance) then closest,distance=other,along end
   end end
   if not closest or (closest.direction or 0)~=d or closest.type==e.type or distance>prototypes.entity[e.name].max_underground_distance then return false end
  end
  return true
 end
 local function prefix(p,extra)
  local belt=belts[key(p.x,p.y)];if not belt then return false end
  local v=vectors[p.dir]
  for step=1,3 do if occupied[key(p.x-v[1]*step,p.y-v[2]*step)] then return false end end
  local ug=underground(belt.name)
  if not prototypes.entity[ug] or prototypes.entity[ug].max_underground_distance<2 or prototypes.entity[ug].belt_speed<prototypes.entity[belt.name].belt_speed then return false end
  extra[#extra+1]=new(ug,p.x-v[1]*3,p.y-v[2]*3,p.dir,{type='input'})
  extra[#extra+1]=sign(p,p.x-v[1]*2,p.y-v[2]*2)
  extra[#extra+1]=new(ug,p.x-v[1],p.y-v[2],p.dir,{type='output'})
  return true
 end
 local function commit(extra)
  for _,e in ipairs(extra) do serial=serial+1;e.entity_number=serial;entities[#entities+1]=e;occupy(e) end
 end
 local function update(p)
  local v=vectors[p.dir];local x,y=p.x-v[1]*3,p.y-v[2]*3
  if p.entry then p.entry.x=x;p.entry.y=y end
  local found=false
  for _,input in ipairs(p.block.external_inputs or {}) do if input.x==p.x and input.y==p.y and input.ingredient==p.name then input.x=x;input.y=y;found=true end end
  if not found then p.block.external_inputs=p.block.external_inputs or {};p.block.external_inputs[#p.block.external_inputs+1]={x=x,y=y,ingredient=p.name,direction=p.dir} end
 end
 local labelled={};local count=0
 -- The connected layout gets one extended input face, including fluid inlets.
 if interface and #ports>0 then
  local extra,valid={},true
  for _,p in ipairs(ports) do if not prefix(p,extra) then valid=false;break end end
  if valid then for _,p in ipairs(interface) do if p.type=='fluid' then
   for step=1,3 do
    if occupied[key(p.x-step,p.y)] then valid=false;break end
    extra[#extra+1]=new(settings.pipe or 'pipe',p.x-step,p.y)
   end
  end end end
  if valid and tunnels_safe(extra) then
   commit(extra)
   for _,p in ipairs(ports) do update(p);labelled[p]=true;count=count+1 end
   for _,p in ipairs(interface) do if p.type=='fluid' then
    for _,b in ipairs(blocks) do for _,input in ipairs(b.external_fluid_inputs or {}) do if input.x==p.x and input.y==p.y and input.fluid==p.name then input.x=input.x-3 end end end
    p.x=p.x-3
   end end
  end
 elseif not interface then
  for _,p in ipairs(ports) do
   local extra={}
   if prefix(p,extra) and tunnels_safe(extra) then commit(extra);update(p);labelled[p]=true;count=count+1 end
  end
 end
 local function approach(x,y)
  for _,p in ipairs(ports) do
   local v=vectors[p.dir];local dx,dy=x-p.x,y-p.y
   if dx*v[2]-dy*v[1]==0 and dx*v[1]+dy*v[2]<0 then return true end
  end
  return false
 end
 local missing=0
 for _,p in ipairs(ports) do if not labelled[p] then
  local v=vectors[p.dir];local found=false
  for distance=1,24 do if found then break end
   for _,side in ipairs({1,-1,2,-2,3,-3,4,-4}) do
    local x,y=p.x-v[1]*distance+v[2]*side,p.y-v[2]*distance-v[1]*side
    if not occupied[key(x,y)] and not approach(x,y) then commit({sign(p,x,y)});count=count+1;found=true;break end
   end
  end
  if not found then missing=missing+1 end
 end end
 report('[BFH-display] External item labels: '..count..'; missing: '..missing)
 return count,missing
end
return M
