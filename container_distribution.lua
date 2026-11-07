local resources=require('resources')
-- One material per ordinary container; every inventory transfer uses a loader.
local M={}
local equipment=require('equipment')
local transfer=require('transfer')
function M.catalog(force)
  local result={}
  for _,name in ipairs(equipment.entities(force,'container')) do
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
  local catalog=transfer.catalog(force);local selected
  for _,name in ipairs(catalog.loaders) do
    if not settings.loader_name or settings.loader_name=='auto' or settings.loader_name==name then
      if not selected or prototypes.entity[name].belt_speed<prototypes.entity[selected].belt_speed then selected=name end
      if prototypes.entity[name].belt_speed>=prototypes.entity[settings.belt_in].belt_speed then selected=name;break end
    end
  end
  if not selected then error({'bfh.container-no-loader'},0) end
  local containers = M.catalog(force)
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
  entities[#entities+1]={entity_number=id,name=box.name,position={x=cx+box.w/2,y=cy+box.h/2}};id=id+1
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
return M
