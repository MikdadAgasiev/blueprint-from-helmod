local resources=require('resources')
-- One material per ordinary container; every inventory transfer uses a loader.
local M={}
local equipment=require('equipment')
local transfer=require('transfer')
function M.catalog(force,excluded)
  local result={}
  for _,name in ipairs(equipment.entities(force,'container',equipment.items(force,excluded))) do
    -- SE uses this inventory as the delivery cannon's receiving target.
    if name ~= 'se-delivery-cannon-chest' then
      local p=prototypes.entity[name]
      local slots=p.get_inventory_size(defines.inventory.chest,'normal') or 0
      if not p.hidden and p.tile_width>=2 and p.tile_height>=2 and slots>0 then
        result[#result+1]={name=name,w=p.tile_width,h=p.tile_height,slots=slots}
      end
    end
  end
  table.sort(result,function(a,b)
    if a.w*a.h~=b.w*b.h then return a.w*a.h<b.w*b.h end
    if a.slots~=b.slots then return a.slots>b.slots end;return a.name<b.name
  end)
  return result
end
function M.context(settings)
  local force=game.forces[settings.force_name or 'player']
  local catalog=transfer.catalog(force,settings.entity_blacklist);local selected
  for _,name in ipairs(catalog.loaders) do
    if not settings.loader_name or settings.loader_name=='auto' or settings.loader_name==name then
      if not selected or prototypes.entity[name].belt_speed<prototypes.entity[selected].belt_speed then selected=name end
      if prototypes.entity[name].belt_speed>=prototypes.entity[settings.belt_in].belt_speed then selected=name;break end
    end
  end
  if not selected then error({'bfh.container-no-loader'},0) end
  local containers = M.catalog(force,settings.entity_blacklist)
  local container_name = settings.container_name or 'auto'
  if container_name == 'se-delivery-cannon-chest' then container_name = 'auto' end
  return {loader=selected,capacity=math.min(prototypes.entity[selected].belt_speed,prototypes.entity[settings.belt_in].belt_speed)*480,
    containers=containers,selected=container_name}
end
function M.select(context,m,n)
  for _,p in ipairs(context.containers) do
    local fits=context.output_collector and n<=p.h and m<=p.h+2*p.w or not context.output_collector and p.h>=m and p.h+2*p.w>=n
    if (context.selected=='auto' or context.selected==p.name) and fits then return p end
  end
end
function M.emit(entities,id,context,settings,m,n,right,py,resource)
  local box=M.select(context,m,n)
  if not box then error({'bfh.container-no-size',m,n},0) end
  local cx,cy=right-box.w-2,py+(context.output_collector and 3 or 2)
  entities[#entities+1]={entity_number=id,name=box.name,position={x=cx+box.w/2,y=cy+box.h/2},bar=context.internal and 1 or nil};id=id+1
  local function add(name,x,y,d,side)
    entities[#entities+1]={entity_number=id,name=name,position={x=x+.5,y=y+.5},direction=d,type=side};id=id+1
    if side=='output' and resource and (prototypes.entity[name].filter_count or 0)>0 then
      local filter=resources.filter(resource);filter.index=1
      entities[#entities].filters={filter};entities[#entities].filter_mode='whitelist'
    end
  end
  local inputs,outputs={},{}
  local function input(x,y,d,dx,dy)
    if #inputs>=m then return end
    add(settings.belt_in,x-2*dx,y-2*dy,d);add(settings.belt_in,x-dx,y-dy,d)
    add(context.loader,x,y,d,'input')
    inputs[#inputs+1]={x=x-2*dx,y=y-2*dy,direction=d}
  end
  for i=0,box.h-1 do input(cx-1,cy+i,4,1,0) end
  if context.output_collector then
    for i=0,box.w-1 do input(cx+i,cy-1,8,0,1) end
    for i=0,box.w-1 do input(cx+i,cy+box.h,0,0,-1) end
  end
  local function output(x,y,d,dx,dy)
    if #outputs>=n then return end
    add(context.loader,x,y,d,'output');add(settings.belt_in,x+dx,y+dy,d)
    outputs[#outputs+1]={x=x+dx,y=y+dy,direction=d}
  end
  for i=0,box.h-1 do output(cx+box.w,cy+i,4,1,0) end
  if not context.output_collector then
    for i=0,box.w-1 do output(cx+i,cy-1,0,0,-1) end
    for i=0,box.w-1 do output(cx+i,cy+box.h,8,0,1) end
  end
  return inputs,outputs,box.h+(context.output_collector and 6 or 4),id
end
-- Refit pool inlets after placement, towards their actual producer. Keeping
-- every inlet on the original face can force a route underneath the inventory.
function M.approach(entities,blocks)
 local cells,sources,rects={},{},{}
 local function footprint(e,value)
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if (e.direction or 0)%8==4 then w,h=h,w end
  for x=math.floor(e.position.x-w/2+.001),math.ceil(e.position.x+w/2-.001)-1 do
   for y=math.floor(e.position.y-h/2+.001),math.ceil(e.position.y+h/2-.001)-1 do cells[x..','..y]=value end
  end
 end
 for _,e in ipairs(entities)do footprint(e,e)end
 for _,b in ipairs(blocks)do
  if b.entity_first and b.entity_last then
   local r={owner=b,left=math.huge,top=math.huge,right=-math.huge,bottom=-math.huge}
   for i=b.entity_first,b.entity_last do local e=entities[i];local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
    if (e.direction or 0)%8==4 then w,h=h,w end
    r.left=math.min(r.left,e.position.x-w/2);r.top=math.min(r.top,e.position.y-h/2)
    r.right=math.max(r.right,e.position.x+w/2);r.bottom=math.max(r.bottom,e.position.y+h/2)
   end
   rects[#rects+1]=r
  end
 end
 for _,b in ipairs(blocks)do for _,p in ipairs(b.output_ports or {})do if p.flow_edge then sources[p.flow_edge]=p end end end
 local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
 local changed=0
 for _,b in ipairs(blocks)do if b.pool_container then
  local box
  for i=b.entity_first,b.entity_last do if prototypes.entity[entities[i].name].type=='container'then box=entities[i];break end end
  if box then
   local proto=prototypes.entity[box.name];local w,h=proto.tile_width,proto.tile_height
   if (box.direction or 0)%8==4 then w,h=h,w end
   local left,top=math.floor(box.position.x-w/2+.001),math.floor(box.position.y-h/2+.001)
   for _,p in ipairs(b.inputs or {})do local source=sources[p.flow_edge];local v=vectors[p.direction]
    if source and v then
     local stub={};for n=0,2 do stub[n+1]=cells[(p.x+n*v[1])..','..(p.y+n*v[2])]end
     if stub[1] and stub[2] and stub[3] and prototypes.entity[stub[3].name].type=='loader-1x1' then
      for _,e in ipairs(stub)do footprint(e,nil)end
      local best={x=p.x,y=p.y,d=p.direction};local score=math.abs(source.x-p.x)+math.abs(source.y-p.y)
      local function offer(x,y,d)
       local dv=vectors[d];local px,py=x-2*dv[1],y-2*dv[2]
       -- Follow the producer's exit direction. A different-facing shortcut
       -- can steal corridors from outgoing consumer branches.
       if source.direction~=d or d==p.direction then return end
       local forward=(px-source.x)*dv[1]+(py-source.y)*dv[2]
       if forward<2 then return end
       local xx,yy=source.x+dv[1],source.y+dv[2]
       local bendx,bendy=dv[1]==0 and px or xx,dv[2]==0 and py or yy
       local function clear_to(tx,ty)
        local dx=tx==xx and 0 or (tx>xx and 1 or -1)
        local dy=ty==yy and 0 or (ty>yy and 1 or -1)
        while xx~=tx or yy~=ty do
         if cells[xx..','..yy]then return false end
         xx,yy=xx+dx,yy+dy
        end
        return true
       end
       if not clear_to(bendx,bendy) or not clear_to(px,py)then return end
       for n=0,2 do local xx,yy=px+n*dv[1],py+n*dv[2]
        if cells[xx..','..yy]then return end
        for _,r in ipairs(rects)do if r.owner~=b and xx+.5>=r.left and xx+.5<r.right and yy+.5>=r.top and yy+.5<r.bottom then return end end
       end
       local cost=math.abs(source.x-px)+math.abs(source.y-py)
       -- A producer on the back side still needs to go around the box.
       if (source.x-px)*dv[1]+(source.y-py)*dv[2]>0 then cost=cost+w+h end
       if cost<score then score=cost;best={x=px,y=py,d=d}end
      end
      for y=top,top+h-1 do offer(left-1,y,4);offer(left+w,y,12)end
      for x=left,left+w-1 do offer(x,top-1,8);offer(x,top+h,0)end
      local dv=vectors[best.d]
      if best.x~=p.x or best.y~=p.y then changed=changed+1 end
      p.x,p.y,p.direction=best.x,best.y,best.d
      for n,e in ipairs(stub)do e.position={x=p.x+(n-1)*dv[1]+.5,y=p.y+(n-1)*dv[2]+.5};e.direction=p.direction;footprint(e,e)end
     end
    end
   end
  end
 end end
 return changed
end
-- Keep a bounded amount in transit, rather than filling every long branch
-- before another consumer receives its share. Native whole-belt reading
-- includes the intervening underground sections; no per-tick script is used.
function M.regulate(entities,blocks,settings)
  local belts={};local count=0
  for _,e in ipairs(entities)do if prototypes.entity[e.name].type=='transport-belt'then
    belts[math.floor(e.position.x)..','..math.floor(e.position.y)]=e
  end end
  local speed=math.min(prototypes.entity[settings.belt_in].belt_speed,prototypes.entity[settings.belt_out].belt_speed)*60
  local red=defines.wire_connector_id.circuit_red
  for _,b in ipairs(blocks)do for _,p in ipairs(b.output_ports or {})do local f=p.flow_buffer
    if f then
      local gate=belts[f.gate.x..','..f.gate.y];local reader=belts[f.reader.x..','..f.reader.y]
      if gate and reader then
        -- Whole-belt reading includes the source loader and the closed gate.
        -- Leave room beyond that stock, otherwise a low-rate outlet can latch
        -- shut forever even though its consumer is empty. Include the reader
        -- tile and any route prefix before the gate, including undergrounds.
        local force=game and game.forces[settings.force_name or 'player']
        local stack=1+(force and force.belt_stack_size_bonus or 0)
        local headroom=8*stack*((f.prefix_tiles or 0)+3)+1
        local buffer=math.max(headroom,math.ceil(f.rate*f.tiles/math.max(speed,.001)*1.25)+8)
        reader.control_behavior={circuit_read_hand_contents=true,
          circuit_contents_read_mode=defines.control_behavior.transport_belt.content_read_mode.entire_belt_hold}
        gate.control_behavior={circuit_enabled=true,circuit_condition={
          first_signal={type='item',name=resources.name(f.item),quality=resources.grade(f.item)},comparator='<',constant=buffer}}
        gate.wires=gate.wires or {};gate.wires[#gate.wires+1]={gate.entity_number,red,reader.entity_number,red}
        count=count+1
      end
    end
  end end
  return count
end
return M
