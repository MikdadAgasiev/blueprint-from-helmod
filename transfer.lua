local equipment_catalog=require('equipment')
-- Machine transfer equipment, applied inside each block before placement and routing.
local M={}
local capacity=require('capacity')
local resources=require('resources')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
local function rotate(p,d)
 local x,y=p.x or p[1],p.y or p[2]
 for _=1,(d or 0)/4 do x,y=-y,x end
 return x,y
end
local function point(p)return p and {x=p.x or p[1],y=p.y or p[2]} end
local function standard(p)
 local a,b=point(p.inserter_pickup_position),point(p.inserter_drop_position)
 if not a or not b then return false end
 return math.abs(a.x)<1e-6 and math.abs(a.y+1)<1e-6 and math.abs(b.x)<1e-6 and b.y>=0.9 and b.y<=1.51
end
function M.catalog(force,excluded)
 local unlocked=equipment_catalog.items(force,excluded)
 local result={inserters={},loaders={},splitters={},available={},place_items={},items=unlocked}
 for name,p in pairs(prototypes.get_entity_filtered({{filter='type',type='inserter'},{filter='type',type='loader-1x1'},{filter='type',type='splitter'}})) do
  if p.type=='inserter' or p.type=='loader-1x1' or p.type=='splitter' then
   local available=false
   for _,v in pairs(p.items_to_place_this or {}) do if unlocked[v.name]==name then available=true;result.place_items[name]=v.name end end
   if available then
    result.available[name]=true
    if p.type=='inserter' and standard(p) and not p.burner_prototype then
     result.inserters[#result.inserters+1]=name
    elseif p.type=='splitter' then result.splitters[#result.splitters+1]=name
    elseif p.type=='loader-1x1' and p.tile_width==1 and p.tile_height==1 and not p.loader_wait_for_full_stack then
     local chute=name=='mdrn-chute-loader' and (not settings.global['mdrn-chute-direction'] or settings.global['mdrn-chute-direction'].value~='input-output')
     local lubricated=name:sub(1,4)=='aai-' and settings.startup['aai-loaders-mode'] and settings.startup['aai-loaders-mode'].value=='lubricated'
     if not lubricated and not chute then result.loaders[#result.loaders+1]=name end
    end
   end
  end
 end
 table.sort(result.inserters);table.sort(result.loaders,function(a,b)local x,y=prototypes.entity[a].belt_speed,prototypes.entity[b].belt_speed;if x~=y then return x<y end;return a<b end);table.sort(result.splitters)
 return result
end
function M.rate(name,force,belt,items,side)
 local p=prototypes.entity[name]
 if not p then return 0 end
 if p.type=='loader-1x1' then return math.min(capacity.belt(belt),p.belt_speed*480) end
 -- Symmetric long-handed arms use the same swing calculation. They are
 -- excluded from automatic one-tile layouts, but explicit two-tile templates
 -- still need a real capacity estimate instead of zero.
 if not standard(p) then
  local a,b=point(p.inserter_pickup_position),point(p.inserter_drop_position)
  if not a or not b or math.abs(a.x)>1e-6 or math.abs(b.x)>1e-6
    or a.y>=-1 or math.abs(a.y+b.y)>0.51 then return 0 end
 end
 local rotation=p.get_inserter_rotation_speed('normal') or 0
 local extension=p.get_inserter_extension_speed('normal') or 0
 if rotation<=0 or extension<=0 then return 0 end
 local bonus=force and (p.uses_inserter_stack_size_bonus and force.inserter_stack_size_bonus or force.bulk_inserter_capacity_bonus) or 0
 local hand=1+(p.inserter_stack_size_bonus or 0)+(bonus or 0)
 if #(items or {})>1 and (p.inserter_max_belt_stack_size or 1)>1 then hand=1 end
 for _,item in ipairs(items or {}) do local p=prototypes.item[resources.name(item)];if p then hand=math.min(hand,p.stack_size) end end
 local a,b=point(p.inserter_pickup_position),point(p.inserter_drop_position)
 local extension_ticks=math.ceil(math.abs(math.sqrt(a.x*a.x+a.y*a.y)-math.sqrt(b.x*b.x+b.y*b.y))/extension)
 local swing=2*math.max(math.ceil(0.5/rotation),extension_ticks)
 -- Allow time for collecting/dropping a hand on one belt lane, plus acquisition.
 local lane=capacity.belt(belt)/2
 local belt_ticks=math.ceil(math.max(0,hand-1)*60/math.max(0.01,lane))
 return hand*60/(swing+belt_ticks+4)
end
local function simpler_inserter(a,b)
 local first,second=prototypes.entity[a],prototypes.entity[b]
 local first_bulk,second_bulk=first.bulk==true,second.bulk==true
 if first_bulk~=second_bulk then return not first_bulk end
 local x,y=first.inserter_stack_size_bonus or 0,second.inserter_stack_size_bonus or 0
 if x~=y then return x<y end
 if first.uses_inserter_stack_size_bonus~=second.uses_inserter_stack_size_bonus then
  return first.uses_inserter_stack_size_bonus==true
 end
 return a<b
end
local function select_inserter(names,required,rate)
 local sufficient,fastest
 local sufficient_speed,fastest_speed=math.huge,0
 for _,name in ipairs(names) do
  local speed=rate(name)
  if speed>0 then
   if speed>fastest_speed then fastest,fastest_speed=name,speed end
   if speed+1e-8>=required and (speed<sufficient_speed
     or (speed==sufficient_speed and simpler_inserter(name,sufficient))) then
    sufficient,sufficient_speed=name,speed
   end
  end
 end
 return sufficient,fastest
end
function M.single_device(options,catalog,force,belt,items,side,selected,required)
 local function rate(name)return M.rate(name,force,belt,items,side) end
 local mode=options.transfer_mode or 'multiple'
 if mode=='auto' then
  local arm=select_inserter(catalog.inserters,required,rate)
  if arm then return arm,false end
 elseif catalog.available[selected] and rate(selected)+1e-8>=required then
  return selected,false
 elseif mode=='faster' then
  local arm=select_inserter(catalog.inserters,required,rate)
  if arm then return arm,false end
 end
 if mode~='auto' and mode~='loaders' then return end
 for _,name in ipairs(catalog.loaders) do
  if (not options.loader_name or options.loader_name=='auto' or options.loader_name==name)
    and rate(name)+1e-8>=required then return name,true end
 end
end
function M.apply(entities,first,meta,recipe,options,en,catalog,force,fluid_ports,report)
 local mode=options.transfer_mode or 'multiple'
 local cells,nodes,machines,arms={},{},{},{}
 local properties={}
 local function geometry(name)
  local p=properties[name]
  if not p then
   local proto=prototypes.entity[name];if not proto then return end
   p={tile_width=proto.tile_width,tile_height=proto.tile_height,type=proto.type}
   if p.type=='underground-belt' then p.max_underground_distance=proto.max_underground_distance end
   properties[name]=p
  end
  return p
 end
 local function insert_cells(e,graph)
  local p=geometry(e.name);if not p then return end
  local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  for xx=x,x+w-1 do for yy=y,y+h-1 do cells[key(xx,yy)]=e end end
  if graph~=false and (p.type=='transport-belt' or p.type=='underground-belt' or p.type=='splitter') then
   nodes[e]={};for xx=x,x+w-1 do for yy=y,y+h-1 do nodes[e][#nodes[e]+1]={x=xx,y=yy} end end
  end
  return x,y,w,h
 end
 -- Include previous blocks in occupancy; never expand over an already built block.
 -- Earlier blocks are obstacles, not part of this block's transfer graph.
 for i,e in ipairs(entities) do insert_cells(e,i>=first) end
 for i=first,#entities do local e=entities[i];local p=prototypes.entity[e.name]
  if e.recipe and (p.type=='assembling-machine' or p.type=='furnace') then
   local x,y,w,h=insert_cells(e);machines[#machines+1]={entity=e,x=x,y=y,w=w,h=h,groups={}}
  elseif p.type=='inserter' then arms[#arms+1]=e end
 end
 if #machines==0 then return en,{} end
 local reserved={};for _,p in ipairs(fluid_ports or {}) do reserved[key(p.x,p.y)]=true end
 local function occupied(x,y)return cells[key(x,y)] or reserved[key(x,y)] end
 local function successors(e)
  local out={};local p=geometry(e.name);local d=e.direction or 0;local v=vectors[d]
  if not v then return out end
  if p.type=='underground-belt' and e.type=='input' then
   local pos=nodes[e][1]
   for distance=1,p.max_underground_distance do
    local other=cells[key(pos.x+v[1]*distance,pos.y+v[2]*distance)]
    if other and other.name==e.name and other.direction==d and other.type=='output' then out[1]=other;break end
   end
  else
   for _,pos in ipairs(nodes[e] or {}) do
    local other=cells[key(pos.x+v[1],pos.y+v[2])]
    if other and other~=e and nodes[other] and (other.direction or 0)~=(d+8)%16 then out[#out+1]=other end
   end
  end
  return out
 end
 local provenance={}
 for _,input in ipairs(meta.inputs or {}) do
  local start=cells[key(input.x,input.y)]
  if start and nodes[start] then
   local queue,seen={start},{[start]=true};local head=1
   while queue[head] do
    local e=queue[head];head=head+1;provenance[e]=provenance[e] or {};provenance[e][input.ingredient]=true
    for _,other in ipairs(successors(e)) do if not seen[other] then seen[other]=true;queue[#queue+1]=other end end
   end
  end
 end
 local incoming,outgoing={},{}
 -- A fractional Helmod machine still crafts at full speed while active.
 -- Size transfer devices for that burst; leave the planned network flow intact.
 local physical_factor=math.max(1,recipe.physical_capacity_factor or 1)
 for _,v in pairs(recipe.ingredients or {}) do if v.type~='fluid' then incoming[v.name]=(incoming[v.name] or 0)+capacity.flow(v,recipe)*physical_factor/#machines end end
 for _,v in pairs(recipe.products or {}) do if v.type~='fluid' then outgoing[v.name]=(outgoing[v.name] or 0)+capacity.flow(v,recipe)*physical_factor/#machines end end
 local function target(x,y)
  for _,m in ipairs(machines) do if x>=m.x and x<m.x+m.w and y>=m.y and y<m.y+m.h then return m end end
 end
 local function belt_at(x,y)local e=cells[key(math.floor(x),math.floor(y))];return e and nodes[e] and e end
 local output_reaches={}
 if meta.product_out then
  local goal=cells[key(meta.product_out.x,meta.product_out.y)]
  local reverse={};for e in pairs(nodes) do for _,other in ipairs(successors(e)) do reverse[other]=reverse[other] or {};reverse[other][#reverse[other]+1]=e end end
  local q,head={},1;if goal then q[1]=goal;output_reaches[goal]=true end
  while q[head] do local e=q[head];head=head+1;for _,other in ipairs(reverse[e] or {}) do if not output_reaches[other] then output_reaches[other]=true;q[#q+1]=other end end end
 end
 local groups={}
 local function assignment(e)
  local p=prototypes.entity[e.name];if not standard(p) then return end
  local ax,ay=rotate(p.inserter_pickup_position,e.direction);local bx,by=rotate(p.inserter_drop_position,e.direction)
  local x,y=e.position.x,e.position.y
  local source,dest=target(x+ax,y+ay),target(x+bx,y+by)
  if dest then return dest,'input',belt_at(x+ax,y+ay) end
  if source then return source,'output',belt_at(x+bx,y+by) end
 end
 for _,e in ipairs(arms) do
  local m,side,belt=assignment(e)
  if m and belt then
   local demands=side=='input' and incoming or outgoing;local names={}
   for name in pairs(demands) do if side=='output' or (provenance[belt] or {})[name] then names[#names+1]=name end end
   if #names==0 then for name in pairs(demands) do names[#names+1]=name end end
   table.sort(names)
   if #names>0 then
    local signature=side..':'..table.concat(names,',');local g=m.groups[signature]
    if not g then g={machine=m,side=side,names=names,arms={},demand=0};m.groups[signature]=g;groups[#groups+1]=g;for _,name in ipairs(names) do g.demand=g.demand+demands[name] end end
    g.arms[#g.arms+1]=e
   end
  end
 end
 local limits={}
 local redundant={}
 local function add(name,x,y,d,kind)
  local e={entity_number=en,name=name,position={x=x+.5,y=y+.5},direction=d};en=en+1
  if kind then e.type=kind end
  entities[#entities+1]=e;insert_cells(e);return e
 end
 local function slots(g)
  local m=g.machine;local result={}
  local function offer(x,y,d)
   if occupied(x,y) then return end
   local v=vectors[d];local b= g.side=='input' and belt_at(x+v[1]+.5,y+v[2]+.5) or belt_at(x-v[1]+.5,y-v[2]+.5)
   if not b then return end
   if g.side=='output' and not output_reaches[b] then return end
   if g.side=='input' then for _,name in ipairs(g.names) do if not (provenance[b] or {})[name] then return end end end
   result[#result+1]={x=x,y=y,d=d}
  end
  -- Direction points from the arm towards its pickup location.
  for y=m.y,m.y+m.h-1 do offer(m.x-1,y,g.side=='input' and 12 or 4);offer(m.x+m.w,y,g.side=='input' and 4 or 12) end
  for x=m.x,m.x+m.w-1 do offer(x,m.y-1,g.side=='input' and 0 or 8);offer(x,m.y+m.h,g.side=='input' and 8 or 0) end
  return result
 end
 -- Collision checks still see foreign belts even though reachability is local.
 local function collision_cells(e)
  if nodes[e] then return nodes[e] end
  local p=geometry(e.name)
  if p.type~='transport-belt' and p.type~='underground-belt' and p.type~='splitter' then return end
  local w,h=p.tile_width,p.tile_height;if e.direction==4 or e.direction==12 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001);local result={}
  for xx=x,x+w-1 do for yy=y,y+h-1 do result[#result+1]={x=xx,y=yy} end end
  return result
 end
 local function splitter_branch(e)
  local v=vectors[e.direction or 0];local x,y=math.floor(e.position.x)+v[1],math.floor(e.position.y)+v[2]
  local feed=cells[key(x,y)]
  if not feed or prototypes.entity[feed.name].type~='transport-belt' then return false end
  local d=feed.direction or 0;local w=vectors[d]
  if w[1]*v[1]+w[2]*v[2]~=0 then return false end
  local before,after=cells[key(x-w[1],y-w[2])],cells[key(x+w[1],y+w[2])]
  if not before or not after or prototypes.entity[before.name].type~='transport-belt' or prototypes.entity[after.name].type~='transport-belt' or (before.direction or 0)~=d or (after.direction or 0)~=d then return false end
  local extra={{x-w[1]+v[1],y-w[2]+v[2]},{x+v[1],y+v[2]},{x+w[1]+v[1],y+w[2]+v[2]}}
  for _,p in ipairs(extra) do if occupied(p[1],p[2]) then return false end end
  for _,p in ipairs(extra) do for _,v2 in pairs(vectors) do
   local other=cells[key(p[1]+v2[1],p[2]+v2[2])]
   local other_cells=other and collision_cells(other)
   if other and other~=before and other~=feed and other~=after and other_cells and not (prototypes.entity[other.name].type=='underground-belt' and other.type=='input') then
    local flow=vectors[other.direction or 0]
    for _,cell in ipairs(other_cells) do if cell.x+flow[1]==p[1] and cell.y+flow[2]==p[2] then return false end end
   end
  end end
  local split=before.name:gsub('transport%-belt','splitter')
  if not catalog.available[split] then
   split=nil;for _,name in ipairs(catalog.splitters) do if prototypes.entity[name].belt_speed>=prototypes.entity[before.name].belt_speed and (not split or prototypes.entity[name].belt_speed<prototypes.entity[split].belt_speed) then split=name end end
  end
  if not split then return false end
  local oldname=before.name
  before.name=split;before.position={x=x-w[1]+v[1]/2+.5,y=y-w[2]+v[2]/2+.5};insert_cells(before)
  feed.direction=((e.direction or 0)+8)%16
  add(oldname,extra[2][1],extra[2][2],d)
  add(oldname,extra[3][1],extra[3][2],((e.direction or 0)+8)%16)
  return true
 end
 for _,g in ipairs(groups) do
  local belt=g.side=='input' and options.belt_in or options.belt_out
  local rates={}
  local function rate(name)
   if not catalog.available[name] then return 0 end
   if rates[name]==nil then rates[name]=M.rate(name,force,belt,g.names,g.side) end
   return rates[name]
  end
  local function total()local value=0;for _,e in ipairs(g.arms) do value=value+rate(e.name) end;return value end
  -- A manually selected locked inserter must not bypass research either.
  for _,e in ipairs(g.arms) do if not catalog.available[e.name] then
   local fallback=catalog.available.inserter and 'inserter' or catalog.inserters[1]
   if fallback then report('[BFH-transfer] locked '..e.name..'; using '..fallback);e.name=fallback end
  end end
  local fastest
  if mode=='faster' or mode=='auto' then
   local _,best=select_inserter(catalog.inserters,0,rate);fastest=best
  end
  if mode=='auto' and fastest then
   local remaining=g.demand
   for i,e in ipairs(g.arms) do
    local required=remaining-(#g.arms-i)*rate(fastest)
    e.name=select_inserter(catalog.inserters,required,rate) or fastest
    remaining=remaining-rate(e.name)
   end
  elseif mode=='faster' and fastest and total()+1e-8<g.demand then
   for _,e in ipairs(g.arms) do if rate(fastest)>rate(e.name) then e.name=fastest end end
  end
  if total()+1e-8<g.demand and (mode=='multiple' or mode=='auto') then
   local name=mode=='auto' and fastest or g.arms[1].name
   if name then for _,slot in ipairs(slots(g)) do
    if total()+1e-8>=g.demand then break end
    local chosen=name
    if mode=='auto' then chosen=select_inserter(catalog.inserters,g.demand-total(),rate) or name end
    g.arms[#g.arms+1]=add(chosen,slot.x,slot.y,slot.d)
   end end
  end
  if total()+1e-8<g.demand and (mode=='loaders' or mode=='auto') then
   local loader
   for _,name in ipairs(catalog.loaders) do
    if (not options.loader_name or options.loader_name=='auto' or options.loader_name==name) then
     local enough=rate(name)+1e-8>=g.demand;local current=loader and rate(loader) or 0
     if not loader or (enough and current+1e-8<g.demand) or (enough and current+1e-8>=g.demand and prototypes.entity[name].belt_speed<prototypes.entity[loader].belt_speed) or (not enough and current+1e-8<g.demand and rate(name)>current) then loader=name end
    end
   end
   if loader then for _,e in ipairs(g.arms) do
    if total()+1e-8>=g.demand then break end
    local _,_,drop_belt=assignment(e)
    local output_ok=g.side=='output' and drop_belt and prototypes.entity[drop_belt.name].type=='transport-belt'
    if rate(loader)>rate(e.name) and (output_ok or (g.side=='input' and splitter_branch(e))) then
     e.name=loader;e.type=g.side=='input' and 'input' or 'output'
     -- Native loader direction is established by the engine regression fixture.
     e.direction=((e.direction or 0)+8)%16
    end
   end end
  end
  -- A loader that covers the operation replaces its redundant helper arms.
  local loader_capacity,loader_count=0,0
  for _,e in ipairs(g.arms) do if prototypes.entity[e.name].type=='loader-1x1' then loader_capacity=loader_capacity+rate(e.name);loader_count=loader_count+1 end end
  if loader_count>0 and loader_capacity+1e-8>=g.demand then
   for i=#g.arms,1,-1 do if prototypes.entity[g.arms[i].name].type=='inserter' then redundant[g.arms[i]]=true;table.remove(g.arms,i) end end
  end
  for _,e in ipairs(g.arms) do local p=prototypes.entity[e.name]
   if p.type=='inserter' and #g.names>1 and (p.inserter_max_belt_stack_size or 1)>1 then e.override_stack_size=1 end
  end
  local achieved=total()
  report(string.format('[BFH-transfer] %s/%s/%s: %.6g/s; need %.6g/s; devices=%d',recipe.name,g.side,table.concat(g.names,','),achieved,g.demand,#g.arms))
  -- Burst headroom is preferred, but an intermittently used machine only
  -- requires its planned average throughput to meet the Helmod target.
  local required=g.demand/physical_factor
  if achieved+1e-8<required then limits[#limits+1]={recipe=recipe.name,side=g.side,items=g.names,capacity=achieved,required=required} end
 end
 for _,m in ipairs(machines) do for _,side in ipairs({'input','output'}) do
  local covered={};for _,g in pairs(m.groups) do if g.side==side then for _,name in ipairs(g.names) do covered[name]=true end end end
  for name,flow in pairs(side=='input' and incoming or outgoing) do if flow>0 and not covered[name] then
   limits[#limits+1]={recipe=recipe.name,side=side,items={name},capacity=0,required=flow/physical_factor}
   report('[BFH-transfer] FAIL no supported '..side..' device for '..name)
  end end
 end end
 for i=#entities,first,-1 do
  local e=entities[i]
  if redundant[e] or (prototypes.entity[e.name].type=='inserter' and not catalog.available[e.name]) then table.remove(entities,i) end
 end
 return en,limits
end
return M
