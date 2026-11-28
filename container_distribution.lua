local resources=require('resources')
-- One material per ordinary container; every inventory transfer uses a loader.
local M={}
local equipment=require('equipment')
local transfer=require('transfer')
local special={['se-delivery-cannon-chest']=true,['se-rocket-launch-pad']=true,['se-rocket-landing-pad']=true}
function M.catalog(force,excluded,allowed,candidates)
  local result={};local items=equipment.items(force,excluded);local placing={}
  for item,name in pairs(items)do if not placing[name]or item<placing[name]then placing[name]=item end end
  for _,name in ipairs(equipment.entities(force,'container',items)) do
    -- SE delivery and cargo-rocket inventories require their own logistics logic.
    if not special[name] then
      local p=prototypes.entity[name]
      local slots=p.get_inventory_size(defines.inventory.chest,'normal') or 0
      local item=placing[name];local ip=item and prototypes.item and prototypes.item[item]
      local category=ip and ip.subgroup and ip.subgroup.name or ''
      local storage=category=='storage'or category=='containers'or category=='warehousing'
        or category:find('^storage%-')~=nil or category:find('^container%-')~=nil
      local enabled=allowed==nil and storage or allowed and allowed[name]==true
      if not p.hidden and p.tile_width>=2 and p.tile_height>=2 and slots>0 and (candidates or enabled)then
        result[#result+1]={name=name,item=item,category=category,storage=storage,w=p.tile_width,h=p.tile_height,slots=slots}
      end
    end
  end
  table.sort(result,function(a,b)
    if a.w*a.h~=b.w*b.h then return a.w*a.h<b.w*b.h end
    if a.slots~=b.slots then return a.slots>b.slots end;return a.name<b.name
  end)
  return result
end
function M.set_allowed(force,settings,name,state)
  if settings.container_allowlist==nil then
    settings.container_allowlist={}
    for _,c in ipairs(M.catalog(force,settings.entity_blacklist))do settings.container_allowlist[c.name]=true end
  end
  settings.container_allowlist[name]=state or nil
  if not state and settings.container_name==name then settings.container_name='auto'end
end
function M.build_selection(parent,force,settings)
  local help=parent.add{type='label',caption={'bfh.storage-help'}};help.style.single_line=false;help.style.maximal_width=510
  for _,c in ipairs(M.catalog(force,settings.entity_blacklist,nil,true))do
    local enabled=settings.container_allowlist==nil and c.storage or settings.container_allowlist and settings.container_allowlist[c.name]==true
    local row=parent.add{type='flow',direction='horizontal'};row.style.vertical_align='center'
    row.add{type='checkbox',state=not not enabled,caption={'','[item='..c.item..'] ',prototypes.entity[c.name].localised_name,' — ',c.w,'×',c.h,'; ',{'bfh.container-slots',c.slots}},
      tags={action='bfh_storage_allowed',entity=c.name},tooltip={'',c.name,'\n',c.category}}
  end
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
  local controller
  for _,name in ipairs(equipment.entities(force,'decider-combinator',catalog.items)) do
    local p=prototypes.entity[name]
    if p.tile_width==1 and p.tile_height==2 then controller=name;break end
  end
  local containers = M.catalog(force,settings.entity_blacklist,settings.container_allowlist)
  local container_name = settings.container_name or 'auto'
  if special[container_name] then container_name = 'auto' end
  return {loader=selected,capacity=math.min(prototypes.entity[selected].belt_speed,prototypes.entity[settings.belt_in].belt_speed)*480,
    containers=containers,selected=container_name,controller=controller,loaders=(not settings.loader_name or settings.loader_name=='auto')and catalog.loaders or {selected}}
end
function M.select(context,m,n)
  for _,p in ipairs(context.containers) do
    local fits=context.output_collector and n<=p.h and m<=p.h+2*p.w or not context.output_collector and p.h>=m and p.h+2*p.w>=n
    if (context.selected=='auto' or context.selected==p.name) and fits then return p end
  end
end
function M.branch_belt(context,fallback,rate,fraction)
  local chosen=fallback
  if rate then for _,name in ipairs(context.auto_belts or{})do
    local speed=prototypes.entity[name].belt_speed
    if speed*480*(fraction or 1)+1e-8>=rate and speed<prototypes.entity[chosen].belt_speed then chosen=name end
  end end
  return chosen
end
function M.emit(entities,id,context,settings,m,n,right,py,resource)
  local box=M.select(context,m,n)
  if not box then error({#context.containers==0 and 'bfh.container-none-enabled'or 'bfh.container-no-size',m,n},0)end
  local cx,cy=right-box.w-2,py+(context.output_collector and 3 or 2)
  local box_id=id
  entities[#entities+1]={entity_number=id,name=box.name,position={x=cx+box.w/2,y=cy+box.h/2}};id=id+1
  local function add(name,x,y,d,side)
    entities[#entities+1]={entity_number=id,name=name,position={x=x+.5,y=y+.5},direction=d,type=side};id=id+1
    if side=='output' and resource and (prototypes.entity[name].filter_count or 0)>0 then
      local filter=resources.filter(resource);filter.index=1
      entities[#entities].filters={filter};entities[#entities].filter_mode='whitelist'
    end
  end
  local inputs,outputs={},{}
  local function transport(side,index)
    local rates=side=='input'and context.input_rates or context.output_rates
    local fractions=side=='output'and context.output_fractions
    local belt=M.branch_belt(context,settings.belt_in,rates and rates[index],fractions and fractions[index])
    local loader=context.loader
    if context.auto_belts then for _,name in ipairs(context.loaders or{})do
      if prototypes.entity[name].belt_speed>=prototypes.entity[belt].belt_speed then loader=name;break end
    end end
    return belt,loader
  end
  local function input(x,y,d,dx,dy)
    if #inputs>=m then return end
    local belt,loader=transport('input',#inputs+1)
    add(belt,x-2*dx,y-2*dy,d);add(belt,x-dx,y-dy,d)
    add(loader,x,y,d,'input')
    inputs[#inputs+1]={x=x-2*dx,y=y-2*dy,direction=d,flow_belt=context.auto_belts and belt or nil}
  end
  for i=0,box.h-1 do input(cx-1,cy+i,4,1,0) end
  if context.output_collector then
    for i=0,box.w-1 do input(cx+i,cy-1,8,0,1) end
    for i=0,box.w-1 do input(cx+i,cy+box.h,0,0,-1) end
  end
  local function output(x,y,d,dx,dy)
    if #outputs>=n then return end
    local belt,loader=transport('output',#outputs+1)
    add(loader,x,y,d,'output');add(belt,x+dx,y+dy,d)
    outputs[#outputs+1]={x=x+dx,y=y+dy,direction=d,flow_belt=context.auto_belts and belt or nil}
  end
  for i=0,box.h-1 do output(cx+box.w,cy+i,4,1,0) end
  if not context.output_collector then
    for i=0,box.w-1 do output(cx+i,cy-1,0,0,-1) end
    for i=0,box.w-1 do output(cx+i,cy+box.h,8,0,1) end
  end
  local extra=0
  if context.internal and context.controller and n>1 then
    local control=id;local signal={type='item',name=resources.name(resource),quality=resources.grade(resource)}
    local item=prototypes.item[resources.name(resource)]
    local threshold=math.min(500,math.max(1,math.floor(box.slots*(item and item.stack_size or 1)/2)))
    entities[#entities+1]={entity_number=id,name=context.controller,position={x=cx-.5,y=cy-2},direction=0,
      control_behavior={decider_conditions={conditions={{first_signal=signal,comparator='>',constant=threshold}},
        -- A shared negative signal cancels the belt quota only above the reserve.
        -- Each outlet keeps its isolated red belt reading; green carries the bypass.
        outputs={{signal=signal,copy_count_from_input=false,constant=-2147483648}},else_outputs={}}},
      wires={{id,defines.wire_connector_id.combinator_input_red,box_id,defines.wire_connector_id.circuit_red}}}
    id=id+1;extra=1
    for _,p in ipairs(outputs)do p.stock_controller_id=control end
  end
  return inputs,outputs,box.h+(context.output_collector and 6 or 4)+extra,id
end
-- Refit pool inlets after placement, towards their actual producer. Keeping
-- every inlet on the original face can force a route underneath the inventory.
function M.approach(entities,blocks)
 local cells,sources,rects,sinks={},{},{},{}
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
 for _,b in ipairs(blocks)do
  for _,p in ipairs(b.output_ports or {})do if p.flow_edge then sources[p.flow_edge]=p end end
  for _,p in ipairs(b.inputs or {})do if p.flow_edge then sinks[p.flow_edge]=p end end
 end
 local protected={}
 for _,r in ipairs(rects)do for x=math.floor(r.left),math.ceil(r.right)-1 do
  local row=protected[x]or{};protected[x]=row
  for y=math.floor(r.top),math.ceil(r.bottom)-1 do row[y]=r.owner end
 end end
 local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
 local changed=0
 for _,b in ipairs(blocks)do if b.pool_container then
  local box
  for i=b.entity_first,b.entity_last do if prototypes.entity[entities[i].name].type=='container'then box=entities[i];break end end
  if box then
   local proto=prototypes.entity[box.name];local w,h=proto.tile_width,proto.tile_height
   if (box.direction or 0)%8==4 then w,h=h,w end
   local left,top=math.floor(box.position.x-w/2+.001),math.floor(box.position.y-h/2+.001)
   -- Bind nearby producers to nearby sockets on the same face. Keeping the
   -- recipe enumeration order forces crossing feeds into an otherwise open bank.
   local inlets={}
   for _,p in ipairs(b.inputs or{})do local v=vectors[p.direction];local cap=math.huge;local valid=v and sources[p.flow_edge]
     if valid then for step=0,2 do local e=cells[(p.x+step*v[1])..','..(p.y+step*v[2])]
       if not e or not prototypes.entity[e.name].belt_speed then valid=false;break end
       cap=math.min(cap,prototypes.entity[e.name].belt_speed*480)
     end end
     if valid then inlets[#inlets+1]={port=p,capacity=cap}end
   end
   local function distance(source,p)return math.abs(source.x-p.x)+math.abs(source.y-p.y)end
   for pass=1,12 do local improved=false
     for i=1,#inlets-1 do for j=i+1,#inlets do local a,c=inlets[i],inlets[j];local p,q=a.port,c.port
       if p.direction==q.direction and (p.graph_rate or 0)<=c.capacity+1e-8 and (q.graph_rate or 0)<=a.capacity+1e-8 then
         local x,z=sources[p.flow_edge],sources[q.flow_edge]
         if distance(x,q)+distance(z,p)<distance(x,p)+distance(z,q)then
           for _,field in ipairs({'flow_edge','graph_rate','layout_rate','ingredient'})do p[field],q[field]=q[field],p[field]end
           sinks[p.flow_edge]=p;sinks[q.flow_edge]=q;improved=true;changed=changed+1
         end
       end
     end end
     if not improved then break end
   end
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
   -- A pool's inner outlet can face a neighbouring production block. Pick
   -- a clear side before other routes consume its only turning pocket.
   for _,p in ipairs(b.output_ports or {})do local target=sinks[p.flow_edge];local v=vectors[p.direction]
    if target and v then
     local stub={};for n=0,1 do stub[n+1]=cells[(p.x-n*v[1])..','..(p.y-n*v[2])]end
     if stub[1]and stub[2]and prototypes.entity[stub[2].name].type=='loader-1x1'then
      for _,e in ipairs(stub)do footprint(e,nil)end
      local function cost(x,y,d)
       local dv=vectors[d];local clearance=17
       for n=1,16 do local xx,yy=x+n*dv[1],y+n*dv[2];local row=protected[xx];local owner=row and row[yy]
        if owner and owner~=b then clearance=n;break end
       end
       return math.abs(target.x-x)+math.abs(target.y-y)+(17-clearance)*16
      end
      local best={x=p.x,y=p.y,d=p.direction};local score=cost(p.x,p.y,p.direction)
      local function offer(x,y,d)
       local dv=vectors[d];local px,py=x+dv[1],y+dv[2]
       for n=0,1 do local xx,yy=px-n*dv[1],py-n*dv[2];local row=protected[xx]
        if cells[xx..','..yy]or(row and row[yy]and row[yy]~=b)then return end
       end
       local value=cost(px,py,d)
       if value<score then score=value;best={x=px,y=py,d=d}end
      end
      for y=top,top+h-1 do offer(left-1,y,12);offer(left+w,y,4)end
      for x=left,left+w-1 do offer(x,top-1,0);offer(x,top+h,8)end
      if best.x~=p.x or best.y~=p.y or best.d~=p.direction then
       local first=b.product_out
       if first and first.x==p.x and first.y==p.y then first.x,first.y,first.direction=best.x,best.y,best.d end
       p.x,p.y,p.direction=best.x,best.y,best.d;changed=changed+1
      end
      local dv=vectors[p.direction]
      for n,e in ipairs(stub)do e.position={x=p.x-(n-1)*dv[1]+.5,y=p.y-(n-1)*dv[2]+.5};e.direction=p.direction;footprint(e,e)end
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
-- Green bypass wires may relay through idle belt connectors. Readers stay
-- exclusively on their branch's red network, so branch counts never mix.
local function stock_wires(entities,controller,targets,readers)
  local nodes={controller};local lookup={};local cells={}
  for _,e in ipairs(entities)do if prototypes.entity[e.name].type=='transport-belt' and not readers[e.entity_number]and not(e.control_behavior and e.control_behavior.circuit_read_hand_contents)then
    nodes[#nodes+1]=e;lookup[e.entity_number]=#nodes
    local x,y=math.floor(e.position.x/8),math.floor(e.position.y/8);cells[x]=cells[x]or{};cells[x][y]=cells[x][y]or{};cells[x][y][#cells[x][y]+1]=#nodes
  end end
  local waiting=0;local wanted={};for _,e in ipairs(targets)do local i=lookup[e.entity_number];if not i then return false end;if not wanted[i]then wanted[i]=true;waiting=waiting+1 end end
  local queue,parent={1},{[1]=0};local head=1
  while queue[head]and waiting>0 do
    local i=queue[head];head=head+1;local e=nodes[i];local proto=prototypes.entity[e.name]
    local reach=proto.get_max_circuit_wire_distance and proto.get_max_circuit_wire_distance('normal')or 9
    if i==1 then reach=math.max(1,reach-.5)end
    for x=math.floor((e.position.x-reach)/8),math.floor((e.position.x+reach)/8)do local row=cells[x]
      if row then for y=math.floor((e.position.y-reach)/8),math.floor((e.position.y+reach)/8)do
        for _,j in ipairs(row[y]or{})do if parent[j]==nil then local other=nodes[j];local p=prototypes.entity[other.name]
          local limit=math.min(reach,p.get_max_circuit_wire_distance and p.get_max_circuit_wire_distance('normal')or 9)
          local dx,dy=e.position.x-other.position.x,e.position.y-other.position.y
          if dx*dx+dy*dy<=limit*limit then parent[j]=i;queue[#queue+1]=j;if wanted[j]then waiting=waiting-1 end end
        end end
      end end
    end
  end
  if waiting>0 then return false end
  local used={};local green=defines.wire_connector_id.circuit_green
  for i in pairs(wanted)do while parent[i]and parent[i]~=0 and not used[i]do
    used[i]=true;local j=parent[i];local from,to=nodes[j],nodes[i]
    from.wires=from.wires or{};from.wires[#from.wires+1]={from.entity_number,j==1 and defines.wire_connector_id.combinator_output_green or green,to.entity_number,green}
    i=j
  end end
  return true
end
function M.regulate(entities,blocks,settings)
  local belts,by_id,readers,stocks={},{},{},{};local count=0
  for _,e in ipairs(entities)do
    by_id[e.entity_number]=e
    if prototypes.entity[e.name].type=='transport-belt'then belts[math.floor(e.position.x)..','..math.floor(e.position.y)]=e end
  end
  for _,b in ipairs(blocks)do for _,p in ipairs(b.output_ports or{})do local f=p.flow_buffer
    local e=f and belts[f.reader.x..','..f.reader.y];if e then readers[e.entity_number]=true end
  end end
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
        -- Native whole-belt reading also includes the consumer's delivery
        -- headers. Their standing inventory must not close the feeder before
        -- items reach the distant machines. Bound this allowance by the
        -- actual consumer geometry, never by an arbitrary unlimited quota.
        local delivery_tiles=0
        if f.delivery_first and f.delivery_last then
          for i=f.delivery_first,f.delivery_last do local e=entities[i]
            local proto=e and prototypes.entity[e.name]
            if proto and proto.type=='transport-belt'then delivery_tiles=delivery_tiles+1
            elseif proto and proto.type=='underground-belt'then
              delivery_tiles=delivery_tiles+1+(proto.max_underground_distance or 0)/2
            end
          end
        end
        local headroom=8*stack*((f.prefix_tiles or 0)+3+delivery_tiles)+1
        local speed=prototypes.entity[gate.name].belt_speed*60
        local buffer=math.max(headroom,math.ceil(f.rate*f.tiles/math.max(speed,.001)*1.25)+8)
        reader.control_behavior={circuit_read_hand_contents=true,
          circuit_contents_read_mode=defines.control_behavior.transport_belt.content_read_mode.entire_belt_hold}
        gate.control_behavior={circuit_enabled=true,circuit_condition={
          first_signal={type='item',name=resources.name(f.item),quality=resources.grade(f.item)},comparator='<',constant=buffer}}
        gate.wires=gate.wires or {};gate.wires[#gate.wires+1]={gate.entity_number,red,reader.entity_number,red}
        if f.stock_controller_id then
          local gates=stocks[f.stock_controller_id]or{};stocks[f.stock_controller_id]=gates;gates[#gates+1]=gate
        end
        count=count+1
      end
    end
  end end
  for id,gates in pairs(stocks)do
    local controller=by_id[id]
    if not controller or not stock_wires(entities,controller,gates,readers)then error('Unable to wire container stock bypass',0)end
  end
  return count
end
return M
