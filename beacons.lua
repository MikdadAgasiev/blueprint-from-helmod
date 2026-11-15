local M={}
local work=require('generation_work')
local equipment=require('helmod_equipment')
local function overlaps(a,b)
  return a.x<b.x+b.w and a.x+a.w>b.x and a.y<b.y+b.h and a.y+a.h>b.y
end
local function rect(e)
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if e.direction==4 or e.direction==12 then w,h=h,w end
  return {x=e.position.x-w/2,y=e.position.y-h/2,w=w,h=h}
end
local function effect_rect(e)
  local p=prototypes.entity[e.name];local b=p.collision_box
  if not b then return rect(e) end
  local a,z=b.left_top or b[1],b.right_bottom or b[2]
  local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
  for _,v in ipairs({{a.x or a[1],a.y or a[2]},{a.x or a[1],z.y or z[2]},{z.x or z[1],a.y or a[2]},{z.x or z[1],z.y or z[2]}}) do
    local x,y=v[1],v[2];for i=1,(e.direction or 0)/4 do x,y=-y,x end
    left=math.min(left,x);top=math.min(top,y);right=math.max(right,x);bottom=math.max(bottom,y)
  end
  return {x=e.position.x+left,y=e.position.y+top,w=right-left,h=bottom-top}
end
local function supplies(b,m,r)
  b=b.effect or b
  return overlaps({x=b.x-r,y=b.y-r,w=b.w+2*r,h=b.h+2*r},m)
end
-- Enumeration can dominate a tick for wide modded beacons. Keep its cursor
-- and candidate list in the serializable work state, just like packing itself.
local function candidate_step(a,s)
 local p=prototypes.entity[a.name];local m=a.machine
 local left,right=math.floor(m.x-a.radius-p.tile_width),math.ceil(m.x+m.w+a.radius)
 local top,bottom=math.floor(m.y-a.radius-p.tile_height),math.ceil(m.y+m.h+a.radius)
 s.x=s.x or left;s.y=s.y or top;s.result=s.result or {}
 while s.x<=right do
  while s.y<=bottom do
   if not work.consume(8) then return false end
   local x,y=s.x,s.y;s.y=s.y+1
   local c={x=x,y=y,w=p.tile_width,h=p.tile_height,radius=a.radius,
    effect=effect_rect{name=a.name,position={x=x+p.tile_width/2,y=y+p.tile_height/2}}}
   local free=true
   for _,receiver in ipairs(a.receivers) do if not supplies(c,receiver,a.radius) then free=false;break end end
   if free then for _,r in ipairs(a.occupied) do if overlaps(c,r) then free=false;break end end end
   if free then s.result[#s.result+1]=c end
  end
  s.y=top;s.x=s.x+1
 end
 table.sort(s.result,function(x,y)
  local dx=math.abs(x.x+x.w/2-a.center_x)+math.abs(x.y+x.h/2-a.center_y)
  local dy=math.abs(y.x+y.w/2-a.center_x)+math.abs(y.y+y.h/2-a.center_y)
  if dx~=dy then return dx<dy end;if x.y~=y.y then return x.y<y.y end;return x.x<y.x
 end)
 return true,s.result
end
work.register('beacon-candidates',candidate_step)
local function module_key(modules)
 local parts={}
 for _,m in ipairs(equipment.modules(modules)) do
  parts[#parts+1]=m.name..'/'..m.quality..'='..m.amount
 end
 return table.concat(parts,';')
end
local function installed_modules(entity)
 local modules={}
 for _,request in ipairs(entity.items or {}) do
  local amount=0
  for _,slot in ipairs((request.items or {}).in_inventory or {}) do amount=amount+(slot.count or 0) end
  if amount>0 then modules[#modules+1]={name=request.id.name,quality=request.id.quality,amount=amount} end
 end
 return module_key(modules)
end
local function step(a,s)
  s.depth=s.depth or 1;s.selected=s.selected or {};s.next=s.next or {};s.nodes=s.nodes or 0
  while s.depth<=#a.slots do
    local depth=s.depth;local kind=a.slots[depth];local options=a.candidates[kind]
    local index=s.next[depth] or (depth>1 and a.slots[depth-1]==kind and s.selected[depth-1].index+1 or 1)
    local found=false
    while index<=#options do
      if not work.consume(4) then s.next[depth]=index;return false end
      s.nodes=s.nodes+1
      if s.nodes>60000 then return true,nil end
      local candidate=options[index];local free=true
      for _,placed in ipairs(s.selected) do if overlaps(candidate,placed) then free=false;break end end
      s.next[depth]=index+1
      if free then
        local placed={x=candidate.x,y=candidate.y,w=candidate.w,h=candidate.h,index=index,kind=kind}
        s.selected[depth]=placed;s.depth=depth+1;s.next[s.depth]=nil;found=true;break
      end
      index=index+1
    end
    if not found then
      s.next[depth]=nil;s.selected[depth]=nil;s.depth=depth-1
      if s.depth<1 then return true,nil end
      s.selected[s.depth]=nil
    end
  end
  return true,s.selected
end
work.register('beacon-pack',step)
function M.has(recipe)return #equipment.beacons(recipe)>0 end
function M.can_share(recipe)
  local types=equipment.beacons(recipe)
  local count=0;for _,b in ipairs(types) do count=count+b.combo end
  if script and script.active_mods and script.active_mods['space-exploration'] and count>1 then return false end
  return count>0 and count<=64
end
function M.plan(list,first,meta,recipe,id,ports,shared)
  local types=equipment.beacons(recipe)
  if #types==0 then return id,meta.height or 0 end
  local machines,occupied={},{}
  for i=first,#list do
    local e=list[i];local p=prototypes.entity[e.name]
    occupied[#occupied+1]=rect(e)
    if e.name==recipe.factory.name then
      machines[#machines+1]=e
    end
  end
  local machine=assert(machines[1],'beacon machine missing')
  if shared then
    if #machines<2 or not M.can_share(recipe) then return end
  elseif #machines~=1 then
    error({'bfh.plan-equipment-invalid','beacon cell contains multiple machines'},0)
  end
  local receiver=prototypes.entity[machine.name].effect_receiver
  if receiver and receiver.uses_beacon_effects==false then error({'bfh.plan-equipment-invalid',machine.name..' / beacon effects disabled'},0) end
  local m=effect_rect(machine)
  local receivers={}
  local center_x,center_y=0,0
  for _,receiver_machine in ipairs(machines) do
    receivers[#receivers+1]=effect_rect(receiver_machine)
    center_x=center_x+receiver_machine.position.x
    center_y=center_y+receiver_machine.position.y
  end
  center_x=center_x/#machines
  center_y=center_y/#machines
  local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local function reserve(p,d,sign)
    local v=vectors[d or 8]
    for n=1,3 do occupied[#occupied+1]={x=p.x+v[1]*n*sign,y=p.y+v[2]*n*sign,w=1,h=1} end
  end
  local function direction(p)
    if p.direction then return p.direction end
    for i=first,#list do local e=list[i];local kind=prototypes.entity[e.name].type
      if (kind=='transport-belt' or kind=='underground-belt' or kind=='splitter') and math.floor(e.position.x)==p.x and math.floor(e.position.y)==p.y then return e.direction or 0 end
    end
    return 8
  end
  for _,p in ipairs(meta.inputs or {}) do reserve(p,direction(p),-1) end
  if meta.product_out then reserve(meta.product_out,direction(meta.product_out),1) end
  for _,p in ipairs(ports or {}) do reserve(p,p.dir,1) end
  local candidates,slots={},{}
  for kind,b in ipairs(types) do
    local p=prototypes.entity[b.name]
    if not p or p.type~='beacon' then error({'bfh.plan-equipment-invalid',b.name},0) end
    local radius=p.get_supply_area_distance(b.quality or 'normal') or 0
    if radius<=0 or b.combo>64 then error({'bfh.plan-equipment-invalid',b.name..' / coverage'},0) end
    -- Validate module compatibility and slot counts before searching geometry.
    equipment.apply({name=b.name},b)
    candidates[kind]=work.operation('beacon-candidates',nil,{name=b.name,radius=radius,
      machine=m,receivers=receivers,occupied=occupied,center_x=center_x,center_y=center_y},true)
    for n=1,b.combo do slots[#slots+1]=kind end
  end
  if script and script.active_mods and script.active_mods['space-exploration'] and #slots>1 then error({'bfh.se-beacon-overload'},0) end
  if #slots>64 then error({'bfh.plan-equipment-invalid','too many beacons per machine'},0) end
  local placed=work.operation('beacon-pack',nil,{slots=slots,candidates=candidates})
  if not placed then
    if shared then return end
    error({'bfh.beacon-placement-failed',recipe.name},0)
  end
  meta.shared_beacon=shared or nil
  local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
  for i=first,#list do local r=rect(list[i]);left=math.min(left,r.x);top=math.min(top,r.y);right=math.max(right,r.x+r.w);bottom=math.max(bottom,r.y+r.h) end
  for _,r in ipairs(placed) do
    local b=types[r.kind];local e={entity_number=id,name=b.name,position={x=r.x+r.w/2,y=r.y+r.h/2}}
    equipment.apply(e,b);list[#list+1]=e;id=id+1
    local radius=candidates[r.kind][r.index].radius
    -- Reserve the entire effect area in the block's bounding box, so rotating
    -- or densely packing another block cannot add unintended beacon effects.
    left=math.min(left,r.x-radius);top=math.min(top,r.y-radius)
    right=math.max(right,r.x+r.w+radius);bottom=math.max(bottom,r.y+r.h+radius)
  end
  left=math.floor(left);top=math.floor(top);right=math.ceil(right);bottom=math.ceil(bottom)
  local dx,dy=meta.offset_x-left,meta.offset_y-top
  for i=first,#list do local e=list[i];e.position.x=e.position.x+dx;e.position.y=e.position.y+dy end
  for _,p in ipairs(meta.inputs or {}) do p.x=p.x+dx;p.y=p.y+dy end
  if meta.product_out then local p=meta.product_out;p.x=p.x+dx;p.y=p.y+dy end
  for _,p in pairs(meta.product_outs or {}) do p.x=p.x+dx;p.y=p.y+dy end
  if meta.mixed_output then local p=meta.mixed_output;p.x=p.x+dx;p.y=p.y+dy end
  meta.width=right-left;meta.height=bottom-top
  meta.protected_bounds={left=meta.offset_x,top=meta.offset_y,right=meta.offset_x+meta.width,bottom=meta.offset_y+meta.height}
  meta.beacon_types=types
  return id,meta.height
end
local function validate_step(a,s)
  s.beacon_keys=s.beacon_keys or {};s.byid=s.byid or {};s.beacons=s.beacons or {};s.issues=s.issues or {};s.index=s.index or 1
  if not s.phase then
    while s.index<=#a.entities do
      if not work.consume(4) then return false end
      local e=a.entities[s.index];s.index=s.index+1;s.byid[e.entity_number]=e
      if prototypes.entity[e.name].type=='beacon' then s.beacons[#s.beacons+1]=e;s.beacon_keys[e.entity_number]=installed_modules(e) end
    end
    if #s.beacons==0 then return true,{} end
    s.phase='machines';s.bi=1;s.mi=1
  end
  while s.bi<=#a.blocks do
    local block=a.blocks[s.bi];local id=(block.machine_ids or {})[s.mi]
    if not id then s.bi=s.bi+1;s.mi=1 else
      local e=s.byid[id]
      if not s.expected then
        s.expected={};s.actual={};s.beacon_i=1
        for _,b in ipairs(equipment.beacons(block.recipe_node)) do local key=b.name..'/'..(b.quality or 'normal')..'/'..module_key(b.modules);s.expected[key]=(s.expected[key] or 0)+b.combo end
      end
      while s.beacon_i<=#s.beacons do
        if not work.consume(4) then return false end
        local b=s.beacons[s.beacon_i];s.beacon_i=s.beacon_i+1
        local p=prototypes.entity[b.name]
        if supplies(effect_rect(b),effect_rect(e),p.get_supply_area_distance(b.quality or 'normal') or 0) then local key=b.name..'/'..(b.quality or 'normal')..'/'..s.beacon_keys[b.entity_number];s.actual[key]=(s.actual[key] or 0)+1 end
      end
      local good=true;for key,n in pairs(s.expected) do if s.actual[key]~=n then good=false end end
      for key,n in pairs(s.actual) do if s.expected[key]~=n then good=false end end
      if not good then s.issues[#s.issues+1]={machine=e.name,recipe=block.recipe_node.name,x=e.position.x,y=e.position.y} end
      s.expected=nil;s.actual=nil;s.mi=s.mi+1
    end
  end
  return true,s.issues
end
work.register('beacon-validation',validate_step)
function M.validate(entities,blocks)
  return work.operation('beacon-validation',nil,{entities=entities,blocks=blocks})
end
function M.counts(entities,recipes)
  local counts,types={},{}
  for _,e in ipairs(entities) do
   if types[e.name]==nil then types[e.name]=prototypes.entity[e.name].type=='beacon' end
   if types[e.name] then
    local key=e.name..'/'..(e.quality or 'normal');counts[key]=counts[key] or {name=e.name,quality=e.quality or 'normal',actual=0,estimated=0,known=true};counts[key].actual=counts[key].actual+1
  end end
  for _,r in ipairs(recipes) do for _,b in ipairs(equipment.beacons(r)) do
    local key=b.name..'/'..(b.quality or 'normal');local c=counts[key]
    if c then
      if type(b.count)=='number' then c.estimated=c.estimated+b.count
      elseif type(b.per_factory)=='number' then c.estimated=c.estimated+(r.factory.count or 1)*b.per_factory+(b.per_factory_constant or 0)
      else c.known=false end
    end
  end end
  local result={};local keys={};for k in pairs(counts) do keys[#keys+1]=k end;table.sort(keys)
  for _,key in ipairs(keys) do local c=counts[key];if c.known then c.estimated=math.ceil(c.estimated-1e-9) end;result[#result+1]=c end
  return result
end
return M
