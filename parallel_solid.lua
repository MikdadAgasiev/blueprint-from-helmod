-- Full-width output collectors: each machine bank has its own belt.
local M={}
local capacity=require('capacity')
local transfer=require('transfer')
function M.plan(r,settings,catalog,force)
 if settings.transfer_mode~='loaders' and settings.transfer_mode~='auto' then return end
 local p=prototypes.entity[(r.factory or {}).name]
 if not p or p.tile_width<2 or p.tile_height<2 or #(r.products or {})~=1 or (r.quality_outputs or 1)>1 then return end
 if #(r.ingredients or {})<1 or #r.ingredients>2 then return end
 for _,v in ipairs(r.ingredients) do if v.type=='fluid' then return end end
 if r.products[1].type=='fluid' then return end
 local count=math.max(1,math.ceil(r.factory.count or 1));if count<2 then return end
 local output=capacity.flow(r.products[1],r)
 -- Sparse one-item crafts can repeatedly choose the same native loader lane.
 -- Do not count both lanes merely because a loader is present. Fast single
 -- machines backpressure both lanes; even packets were verified separately.
 if output/count<=capacity.belt(settings.belt_out)/2+1e-8 then
  local packet=0;local recipe=prototypes.recipe[r.name]
  for _,v in ipairs(recipe and recipe.products or {}) do if v.type~='fluid' and v.name==r.products[1].name then
   if not v.amount or v.amount%2~=0 then return end
   packet=packet+v.amount
  end end
  if packet==0 or ((r.factory.effects or {}).productivity or 0)>0 then return end
  if ((p.effect_receiver or {}).base_effect or {}).productivity and p.effect_receiver.base_effect.productivity>0 then return end
  for _,m in pairs(r.factory.modules or {}) do
   local q=type(m.quality)=='string' and m.quality or (m.quality and m.quality.name) or 'normal'
   local item=prototypes.item[m.name]
   if item and ((item.get_module_effects(q) or {}).productivity or 0)>0 then return end
  end
 end
 -- Preserve the smaller legacy template when its output lanes already fit.
 if output*math.ceil(count/2)/count<=capacity.belt(settings.belt_out)/2+1e-8 then return end
 local function loader(belt,demand)
  for _,name in ipairs(catalog.loaders) do
   if (not settings.loader_name or settings.loader_name=='auto' or name==settings.loader_name) and transfer.rate(name,force,belt,{},'output')+1e-8>=demand then return name end
  end
 end
 local output_loader=loader(settings.belt_out,output/count)
 if not output_loader then return end
 local names,input_rate={},0
 for _,v in ipairs(r.ingredients) do names[#names+1]=v.name;input_rate=input_rate+capacity.flow(v,r)/count end
 local input,input_loader=transfer.single_device(settings,catalog,force,settings.belt_in,names,'input',settings.inserter_in,input_rate)
 if not input then return end
 local function splitter(belt)
  local chosen
  for _,name in ipairs(catalog.splitters) do if capacity.belt(name)+1e-8>=capacity.belt(belt) and (not chosen or capacity.belt(name)<capacity.belt(chosen)) then chosen=name end end
  return chosen
 end
 local out_split=splitter(settings.belt_out);local in_split=input_loader and splitter(settings.belt_in)
 if not out_split or (input_loader and not in_split) then return end
 return {output=output_loader,input=input,input_loader=input_loader,out_split=out_split,in_split=in_split}
end
function M.build(r,settings,config,ox,oy,en,entities,header)
 local first=#entities+1
 local p=prototypes.entity[r.factory.name];local W,H=p.tile_width,p.tile_height
 local count=math.ceil(r.factory.count);local pad=config.input_loader and 3 or 2
 local width=2*W+2*pad+6;local top=3;local stride=math.max(H,3)
 local rows=math.ceil(count/2);local bottom=top+(rows-1)*stride+H+1
 local left_trunk=pad+W+2;local right_trunk=left_trunk+1
 local function add(name,x,y,w,h,d,extra)
  local e={entity_number=en,name=name,position={x=ox+x+w/2,y=oy+y+h/2},direction=d or 0};en=en+1
  for k,v in pairs(extra or {}) do e[k]=v end;entities[#entities+1]=e
 end
 en=header(#r.ingredients,width,settings.belt_in,ox,oy,en,entities)
 local ports={}
 for side=0,1 do
  local n=side==0 and math.ceil(count/2) or math.floor(count/2)
  local outer=side==0 and 0 or width-1;local flow=side==0 and 4 or 12
  local mx=side==0 and pad or width-pad-W
  local device=side==0 and mx+W or mx-1
  local feeder=side==0 and device+1 or device-1
  local trunk=side==0 and left_trunk or right_trunk
  for y=3,top+n*stride-1 do add(settings.belt_in,outer,y,1,1,8) end
  for y=top+H,bottom do add(settings.belt_out,trunk,y,1,1,8) end
  for row=0,n-1 do
   local y=top+row*stride;local feed=y+H-1
   add(r.factory.name,mx,y,W,H,0,{recipe=r.name})
   local input_x=side==0 and pad-1 or width-pad
   if config.input_loader then
    local branch=side==0 and 1 or width-2
    -- A tap occupies the two outside columns, never the machine footprint.
    for i=#entities,1,-1 do local e=entities[i]
     if e.name==settings.belt_in and math.floor(e.position.x)==ox+outer and math.floor(e.position.y)==oy+feed-1 then table.remove(entities,i);break end
    end
    add(config.in_split,math.min(outer,branch),feed-1,2,1,8)
    add(settings.belt_in,branch,feed,1,1,flow)
   end
   add(config.input,input_x,feed,1,1,config.input_loader and flow or (flow+8)%16,config.input_loader and {type='input'} or nil)
   add(config.output,device,feed,1,1,flow,{type='output'})
   -- The isolated corner preserves both loader lanes before the merger.
   add(settings.belt_out,feeder,feed,1,1,8)
   local sy=feed+1
   for i=#entities,1,-1 do local e=entities[i]
    if e.name==settings.belt_out and math.floor(e.position.x)==ox+trunk and math.floor(e.position.y)==oy+sy then table.remove(entities,i);break end
   end
   add(config.out_split,math.min(feeder,trunk),sy,2,1,8,{output_priority=side==0 and 'left' or 'right'})
  end
  ports[#ports+1]={x=ox+trunk,y=oy+bottom,direction=8,share=n/count}
 end
 local rate=capacity.flow(r.products[1],r)
 if rate<=capacity.belt(settings.belt_out)+1e-8 then
  add(config.out_split,left_trunk,bottom+1,2,1,8,{output_priority='right'})
  add(settings.belt_out,left_trunk,bottom+2,1,1,8)
  ports={{x=ox+left_trunk,y=oy+bottom+2,direction=8,share=1}};bottom=bottom+2
 end
 local inputs={};local split=math.floor((width-1)/2)-1
 for i,v in ipairs(r.ingredients) do inputs[#inputs+1]={x=ox+split+(i-1)*2,y=oy,ingredient=v.name} end
 -- Match the common external frame: input from the left, outputs to the right.
 -- Rotating an isolated block during packing used to leave this useful
 -- orientation untested, despite much shorter connections to the collector.
 for j=first,#entities do local e=entities[j];local x,y=e.position.x-ox,e.position.y-oy
  e.position.x=ox+y;e.position.y=oy+width-x;e.direction=((e.direction or 0)+12)%16
 end
 for _,list in ipairs({inputs,ports}) do for _,p in ipairs(list) do
  local x,y=p.x-ox,p.y-oy;p.x=ox+y;p.y=oy+width-1-x;p.direction=4
 end end
 return en,width,{offset_x=ox,offset_y=oy,width=bottom+1,height=width,inputs=inputs,ingredients={},products={r.products[1].name},output_ports=ports,
  product_out={x=ports[1].x,y=ports[1].y,direction=4},direct_equipment=true,parallel_outputs=true,is_single_assembler_block=true}
end
return M
