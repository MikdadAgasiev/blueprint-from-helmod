local M={}
local capacity=require('capacity')
local orientation=require('orientation')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end

-- Only change lanes if the finished route preserves them to a useful outlet.
-- A single-input bend preserves lanes. A merge or splitter is left alone.
local work=require('generation_work')
local function direction(e)return e.direction or 0 end
local function vector(value,e)
 return orientation.point({x=value.x or value[1],y=value.y or value[2]},direction(e)/4,false)
end
local function mark_cells(cells,e,p,value)
 local w,h=p.tile_width,p.tile_height
 if direction(e)%8==4 then w,h=h,w end
 local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
 for xx=x,x+w-1 do for yy=y,y+h-1 do cells[key(xx,yy)]=value end end
end
local function feeder(belts,x,y,d)
 local e=belts[key(x,y)]
 return e and e.d==d and e.ending~='input'
end
local function connections(belts,x,y,d)
 local v=vectors[d];local dx,dy=-v[2],v[1]
 local back=feeder(belts,x-v[1],y-v[2],d)
 local left=feeder(belts,x+dx,y+dy,(d+12)%16)
 local right=feeder(belts,x-dx,y-dy,(d+4)%16)
 return (back and 1 or 0)+(left and 1 or 0)+(right and 1 or 0),left or right
end
work.register('preserved-inserter-lanes',function(args,state)
 if not state.phase then
  state.phase='rates';state.i=1;state.belts={};state.machines={};state.arms={};state.ends={};state.groups={};state.order={};state.memo={};state.limits={};state.changes={};state.rates={}
  for _,p in ipairs(args.outputs or {}) do if p.type=='item' then state.ends[key(p.x,p.y)]=true end end
 end
 if state.phase=='rates' then
  while state.i<=#args.blocks do
   if not work.consume(16) then return false end
   local b=args.blocks[state.i];local recipe=b.recipe_node;local ids=b.machine_ids or {}
   if recipe and #ids>0 then
    local product
    for _,item in ipairs(recipe.products or {}) do if item.type~='fluid' then
     if product then product=nil;break end;product=item
    end end
    if product then
     local rate=capacity.flow(product,recipe)/#ids
     for _,id in ipairs(ids) do state.rates[id]=rate end
    end
   end
   state.i=state.i+1
  end
  state.phase='index';state.i=1
 end
 if state.phase=='index' then
  while state.i<=#args.entities do
   if not work.consume(12) then return false end
   local i=state.i;local e=args.entities[i];local p=prototypes.entity[e.name];state.i=i+1
   if p.type=='transport-belt' or p.type=='splitter' or p.type=='underground-belt' or p.type=='loader-1x1' or p.type=='loader' then
    mark_cells(state.belts,e,p,{kind=p.type,d=direction(e),ending=e.type,name=e.name,reach=p.type=='underground-belt' and p.max_underground_distance})
   elseif e.recipe and prototypes.recipe[e.recipe] then
    local product
    for _,item in ipairs(prototypes.recipe[e.recipe].products) do
     if item.type=='item' then if product then product=nil;break end;product=item.name end
    end
    if product then
     mark_cells(state.machines,e,p,{id=e.entity_number,product=e.name..'/'..e.recipe..'/'..product,arms=0})
    end
   elseif p.type=='inserter' and p.inserter_pickup_position and p.inserter_drop_position and vectors[direction(e)] then
    local pickup=e.pickup_position or vector(p.inserter_pickup_position,e)
    local drop=e.drop_position or vector(p.inserter_drop_position,e)
    local source=key(math.floor(e.position.x+pickup.x),math.floor(e.position.y+pickup.y))
    state.arms[#state.arms+1]={i=i,source=source,drop=drop}
   end
  end
  state.phase='ends';state.i=1
 end
 if state.phase=='ends' then
  while state.i<=#state.arms do
   if not work.consume(8) then return false end
   local arm=state.arms[state.i];local e=args.entities[arm.i]
   local target=key(math.floor(e.position.x+arm.drop.x),math.floor(e.position.y+arm.drop.y))
   if state.machines[target] then
    state.ends[arm.source]=true
   end
   local source=state.machines[arm.source]
   if source and state.belts[target] then source.arms=source.arms+1 end
   state.i=state.i+1
  end
  state.phase='arms';state.i=1
 end
 if state.phase=='arms' then
  while state.i<=#state.arms do
   if not work.consume(8) then return false end
   local arm=state.arms[state.i];local e=args.entities[arm.i];local facing=vectors[direction(e)]
   local bx,by=math.floor(e.position.x+arm.drop.x),math.floor(e.position.y+arm.drop.y)
   local origin=key(bx,by);local belt=state.belts[origin];local v=belt and vectors[belt.d]
   local turn
   if v then local _,side=connections(state.belts,bx,by,belt.d);turn=side end
   if belt and belt.kind=='transport-belt' and v and not turn then
    local path=state.path
    if not path then path={x=bx,y=by,visited={},seen={},limit=math.huge};state.path=path end
    local terminal
    while terminal==nil do
     if not work.consume(16) then return false end
     local x,y=path.x,path.y;local k=key(x,y)
     if state.memo[k]~=nil then
      terminal=state.memo[k]
      if terminal then path.limit=math.min(path.limit,state.limits[k]) end
     elseif path.seen[k] then terminal=false
     else
      path.visited[#path.visited+1]=k;path.seen[k]=true
      local current=state.belts[k];local d=current.d;local step=vectors[d]
      path.limit=math.min(path.limit,capacity.belt(current.name)/2)
      local count,side=connections(state.belts,x,y,d)
      if count>1 or (current.kind=='underground-belt' and side) then terminal=false
      elseif current.kind=='underground-belt' and current.ending=='input' then
       terminal=false
       for distance=1,math.min(current.reach or 0,64) do
        local nx,ny=x+step[1]*distance,y+step[2]*distance
        local other=state.belts[key(nx,ny)]
        if other and other.kind=='underground-belt' and other.name==current.name and other.d%8==d%8 then
         if other.d==d and other.ending=='output' then path.x,path.y=nx,ny;terminal=nil end
         break
        end
       end
      else
       local nx,ny=x+step[1],y+step[2]
       local next_belt=state.belts[key(nx,ny)]
       if not next_belt then terminal=state.ends[k] and k or false
       elseif next_belt.kind=='transport-belt' and vectors[next_belt.d] and next_belt.d~=(d+8)%16 then path.x,path.y=nx,ny
       elseif next_belt.kind=='underground-belt' and next_belt.ending=='input' and next_belt.d==d then path.x,path.y=nx,ny
       else terminal=false end
      end
     end
    end
    for _,k in ipairs(path.visited) do state.memo[k]=terminal;state.limits[k]=path.limit end
    state.path=nil
    if terminal then
     local group=state.groups[terminal]
     if not group then
      group={arms={},load={0,0},original={0,0},changes={},limit=path.limit};state.groups[terminal]=group;state.order[#state.order+1]=terminal
     end
     group.limit=math.min(group.limit,path.limit)
     local machine=state.machines[arm.source]
     local weight=machine and machine.arms>0 and state.rates[machine.id] and state.rates[machine.id]/machine.arms
     if not weight or (group.product and machine.product~=group.product) then group.blocked=true end
     if machine then group.product=group.product or machine.product end
     local cross=v[1]*(e.position.y+arm.drop.y-by-.5)-v[2]*(e.position.x+arm.drop.x-bx-.5)
     if weight and math.abs(cross)>1e-6 then
      local lane=cross>0 and 1 or 2
      group.original[lane]=group.original[lane]+weight
      if prototypes.entity[e.name].allow_custom_vectors and not e.drop_position and not e.name:find('miniloader%-inserter')
        and facing[1]*v[1]+facing[2]*v[2]==0
        and bx==math.floor(e.position.x)-facing[1] and by==math.floor(e.position.y)-facing[2] then
       group.arms[#group.arms+1]={i=arm.i,drop=arm.drop,lane=lane,bx=bx,by=by,weight=weight}
      else group.load[lane]=group.load[lane]+weight end
     else group.blocked=true end
    end
   end
   state.i=state.i+1
  end
  state.phase='choose';state.i=1
 end
 while state.i<=#state.order do
  if not work.consume(16) then return false end
  local group=state.groups[state.order[state.i]]
  state.arm=state.arm or 1
  if not group.blocked and math.max(group.original[1],group.original[2])>group.limit+1e-8 then
   while state.arm<=#group.arms do
    if not work.consume(8) then return false end
    local arm=group.arms[state.arm];local e=args.entities[arm.i];local load=group.load
    local lane=load[1]==load[2] and arm.lane or (load[1]<load[2] and 1 or 2)
    if lane~=arm.lane then
     group.changes[#group.changes+1]={i=arm.i,drop={
      x=2*(arm.bx+.5-e.position.x)-arm.drop.x,y=2*(arm.by+.5-e.position.y)-arm.drop.y}}
    end
    load[lane]=load[lane]+arm.weight;state.arm=state.arm+1
   end
   if math.max(group.load[1],group.load[2])+1e-8<math.max(group.original[1],group.original[2]) then
    for _,change in ipairs(group.changes) do state.changes[#state.changes+1]=change end
   end
  end
  state.i=state.i+1;state.arm=nil
 end
 return true,state.changes
end)
function M.inserter_lanes(entities,outputs,blocks)
 if not script or not script.active_mods.ChangeInserterDropLane or script.active_mods.bobinserters then return {} end
 return work.operation('preserved-inserter-lanes',nil,{entities=entities,outputs=outputs,blocks=blocks},true)
end
-- Split a stream, then side-load its halves onto opposite output lanes.
-- Balance EACH odd-bank producer before merging: balancing an already
-- overloaded 9/6 stream after a 7.5-per-lane bottleneck is too late.
function M.emit(entities,en,belt,splitter,x,y,d,reuse_input)
 local turns=((d-4)/4)%4
 local function add(name,dx,dy,dir)
  for _=1,turns do dx,dy=-dy,dx end
  entities[#entities+1]={entity_number=en,name=name,position={x=x+.5+dx,y=y+.5+dy},direction=(dir+turns*4)%16};en=en+1
 end
 if not reuse_input then add(belt,0,0,4) end
 add(splitter,1,-.5,4)
 add(belt,2,-1,4);add(belt,3,-1,8)
 add(belt,2,0,8);add(belt,2,1,4);add(belt,3,1,0)
 add(belt,3,0,4);add(belt,4,0,4)
 local v=vectors[d]
 return en,{x=x+4*v[1],y=y+4*v[2],direction=d}
end
function M.attach(entities,first,meta,count,settings,en,rates,splitter,catalog)
 if settings.link_mode=='independent' or count<3 or count%2==0 or not meta.product_out
   or meta.output_ports or meta.product_outs or #meta.products~=1 then return en end
 local product=meta.products[1];local belt=settings.belt_out or 'transport-belt'
 if (rates[product] or 0)<=capacity.belt(belt)/2+1e-8 then return en end
 local p=meta.product_out;local d=p.direction or 8;local reuse=false
 for i=first,#entities do local e=entities[i]
  if math.floor(e.position.x)==p.x and math.floor(e.position.y)==p.y then
   if prototypes.entity[e.name].type~='transport-belt' then return en end
   reuse=true;break
  end
 end
 if catalog and (not splitter or not catalog.available[splitter]) then
  splitter=nil
  for _,name in ipairs(catalog.splitters) do
   if capacity.belt(name)+1e-8>=capacity.belt(belt) and
     (not splitter or capacity.belt(name)<capacity.belt(splitter)) then splitter=name end
  end
 end
 if not splitter or not prototypes.entity[splitter] or capacity.belt(splitter)+1e-8<capacity.belt(belt) then error({'bfh.lane-balance-no-splitter'},0) end
 local next_id,out=M.emit(entities,en,belt,splitter,p.x,p.y,d,reuse)
 p.x,p.y,p.direction=out.x,out.y,out.direction
 meta.balanced_output=true
 return next_id
end
return M
