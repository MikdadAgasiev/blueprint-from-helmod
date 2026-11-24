-- Launch products arrive at a cargo landing pad, not in the silo output.
local M={}
local resources=require('resources')
local capacity=require('capacity')
local equipment=require('equipment')
local transfer=require('transfer')
local work=require('generation_work')
function M.apply(es,bs,s,id,catalog,force)
 local outputs,keys,silos,launches={},{},{},{}
 local bottom=0
 for _,b in ipairs(bs)do
  bottom=math.max(bottom,(b.offset_y or 0)+(b.height or 0))
  if b.launch_products then
   for _,p in ipairs(b.recipe_node.products or {})do
    if not outputs[p.name]then outputs[p.name]=0;keys[#keys+1]=p.name end
    outputs[p.name]=outputs[p.name]+capacity.flow(p,b.recipe_node)
   end
   for i=b.entity_first,b.entity_last do if prototypes.entity[es[i].name].type=='rocket-silo'then silos[#silos+1]=es[i]end end
   launches[#launches+1]=b
  end
 end
 if #keys==0 then return id end
 local pads=equipment.entities(game.forces[s.force_name or 'player'],'cargo-landing-pad',equipment.items(game.forces[s.force_name or 'player'],s.entity_blacklist))
 local pad;for _,name in ipairs(pads)do if name=='cargo-landing-pad'then pad=name;break end end;if not pad then error({'bfh.launch-no-pad'},0)end
 table.sort(keys)
 local p=prototypes.entity[pad];local W,H=p.tile_width,p.tile_height
 local label=s.launch_pad_name or ('BFH '..game.tick)
 local first=#es+1;local y=bottom+4;local ports,products,pending={},{},{}
 local function add(name,x,yy,w,h,d,extra)
  local e={entity_number=id,name=name,position={x=x+w/2,y=y+yy+h/2},direction=d or 0};id=id+1
  for k,v in pairs(extra or {})do e[k]=v end;pending[#pending+1]=e
 end
 add(pad,3,3,W,H,0,script.active_mods['space-exploration'] and {tags={name=label}} or nil)
 local slots={}
 for yy=3,H+2 do slots[#slots+1]={x=W+3,y=yy,dx=1,dy=0,d=4}end
 for yy=3,H+2 do slots[#slots+1]={x=2,y=yy,dx=-1,dy=0,d=12}end
 for x=3,W+2 do slots[#slots+1]={x=x,y=2,dx=0,dy=-1,d=0}end
 for x=3,W+2 do slots[#slots+1]={x=x,y=H+3,dx=0,dy=1,d=8}end
 local slot=0;local belt_capacity=capacity.belt(s.belt_out)
 for _,name in ipairs(keys)do
  local rate=outputs[name];products[#products+1]={name=name,type='item',count=rate}
  local n=math.max(1,math.ceil(rate/belt_capacity-1e-9))
  if #keys>1 and n>1 then error({'bfh.launch-pad-outputs'},0)end
  for _=1,n do
   slot=slot+1;local pos=slots[slot];if not pos then error({'bfh.launch-pad-outputs'},0)end
   local device,loader=transfer.single_device(s,catalog,force,s.belt_out,{name},'output',s.inserter_out,rate/n)
   if not device or (prototypes.entity[device].filter_count or 0)<1 then error({'bfh.launch-no-unloader'},0)end
   local filter=resources.filter(name);filter.index=1
   local extra={filters={filter},filter_mode='whitelist'}
   if loader then extra.type='output'else extra.use_filters=true end
   add(device,pos.x,pos.y,1,1,loader and pos.d or (pos.d+8)%16,extra)
   local x,yy=pos.x+pos.dx,pos.y+pos.dy
   add(s.belt_out,x,yy,1,1,pos.d)
   ports[#ports+1]={x=x,y=y+yy,direction=pos.d,product=name,rate=rate/n,share=1/n}
  end
 end
 -- Equipment enumeration may yield. Commit only after it and validation,
 -- otherwise replay would see erased launch products and omit the receiver.
 for _,b in ipairs(launches)do
  b.recipe_node=work.copy(b.recipe_node);b.recipe_node.products={}
  b.products={};b.product_out=nil;b.output_ports={};b.launch_products=nil
 end
 if script.active_mods['space-exploration']then for _,e in ipairs(silos)do e.tags=e.tags or {};e.tags.landing_pad_name=label end end
 for _,e in ipairs(pending)do es[#es+1]=e end
 local by_product
 if #keys>1 then by_product={};for _,port in ipairs(ports)do by_product[port.product]=work.copy(port) end end
 bs[#bs+1]={product_outs=by_product,offset_x=0,offset_y=y,width=W+6,height=H+6,entity_first=first,entity_last=#es,
  inputs={},output_ports=ports,product_out=work.copy(ports[1]),products=keys,machine_ids={},direct_equipment=true,
  recipe_node={name='__bfh_launch_products__',base_time=1,factory={name=pad,count=1},ingredients={},products=products}}
 return id
end
-- Cargo pads have a forced building grid. Align the entire blueprint,
-- preserving relative positions of the pad, unloaders and connected belts.
function M.align_blueprint(blueprint)
 for _,e in ipairs(blueprint.get_blueprint_entities() or {})do
  local p=prototypes.entity[e.name]
  if p.type=='cargo-landing-pad' and p.build_grid_size>1 then
   local grid=p.build_grid_size
   local origin={x=(-e.position.x)%grid,y=(-e.position.y)%grid}
   blueprint.blueprint_snap_to_grid={x=grid,y=grid}
   blueprint.blueprint_absolute_snapping=true
   blueprint.blueprint_position_relative_to_grid=origin
   return origin
  end
 end
 return {x=0,y=0}
end
return M
