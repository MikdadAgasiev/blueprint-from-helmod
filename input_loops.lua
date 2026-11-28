-- Recirculate a sparse launch-product feed instead of stranding a batch at its tail.
local M={}
local capacity=require('capacity')
local transfer=require('transfer')
function M.apply(es,first,meta,r,count,s,id,catalog,force,batches)
 local long='long-handed-inserter'
 local function unchanged()return id,0 end
 if s.transfer_mode~='auto' and s.transfer_mode~='auto_equipment' then return unchanged()end
 if meta.direct_equipment or meta.ing_count~=3 or count<6 or count%4~=2
  or(s.transport_quality or 'normal')~='normal' or not catalog.available[long]then return unchanged()end
 local p=prototypes.entity[long];local pick=p and p.inserter_pickup_position;local drop=p and p.inserter_drop_position
 if not pick or not drop or math.abs(pick.x or pick[1] or 0)>1e-6 or(pick.y or pick[2])~=-2
  or math.abs(drop.x or drop[1] or 0)>1e-6 or(drop.y or drop[2] or 0)<1.9 or(drop.y or drop[2])>2.51 then return unchanged()end
 local name=meta.ingredients[3]
 if not batches[name]or not r.factory then return unchanged()end
 local machine=prototypes.entity[r.factory.name]
 if not machine or machine.tile_width~=3 or machine.tile_height~=3 then return unchanged()end
 local item
 for _,v in ipairs(r.ingredients or{})do if v.type=='fluid'then return unchanged()end;if v.name==name then item=v end end
 if not item or transfer.rate(long,force,s.belt_in,{name},'input')*.8+1e-8<capacity.flow(item,r)/count then return unchanged()end
 local top,bottom=meta.offset_y+5,meta.offset_y+6+count/2*3-1
 local cells={};local function key(x,y)return x..','..y end
 for i=first,#es do local e=es[i];cells[key(math.floor(e.position.x),math.floor(e.position.y))]=e end
 local sides={}
 for side=0,1 do
  local outer=meta.offset_x+(side==0 and 0 or meta.width-1);local step=side==0 and 1 or -1
  local header=cells[key(outer,top)];local tail=cells[key(outer,bottom)]
  local inner=cells[key(outer+step,bottom)];local arm=cells[key(outer+2*step,bottom)]
  local inward=side==0 and 4 or 12
  if not header or header.name~=s.belt_in or header.direction~=8
   or not tail or tail.name~=s.belt_in or tail.direction~=inward
   or not inner or inner.name~=s.belt_in or inner.direction~=inward
   or not arm or prototypes.entity[arm.name].type~='inserter' or arm.direction~=(inward+8)%16
   or arm.pickup_position or arm.drop_position then return unchanged()end
  for y=top,bottom do if cells[key(outer-step,y)]then return unchanged()end end
  sides[#sides+1]={outer=outer,step=step,tail=tail,inner=inner,arm=arm,inward=inward}
 end
 local output_arms,bridges={},{}
 if meta.power_gap==1 then
  local required=0;for _,v in ipairs(r.products or{})do required=required+capacity.flow(v,r)/count end
  if transfer.rate(long,force,s.belt_out,{meta.products[1]},'output')*.8+1e-8<required then return unchanged()end
  local column=meta.offset_x+meta.width-7
  for i=first,#es do local e=es[i]
   if e.position.x==column+.5 and prototypes.entity[e.name].type=='inserter'and e.direction==4 then
    local bridge=cells[key(column-1,math.floor(e.position.y))]
    if not bridge or bridge.name~=s.belt_out or bridge.direction~=12 or e.pickup_position or e.drop_position then return unchanged()end
    output_arms[#output_arms+1]=e;bridges[bridge]=true
   end
  end
  if #output_arms~=count/2 then return unchanged()end
 end
 -- Validate both banks before editing either; manual choices and blocked return paths stay intact.
 local remove=bridges
 for _,arm in ipairs(output_arms)do arm.name=long end
 for _,side in ipairs(sides)do
  side.tail.direction=(side.inward+8)%16;side.arm.name=long;remove[side.inner]=true
  for y=top,bottom do
   es[#es+1]={entity_number=id,name=s.belt_in,position={x=side.outer-side.step+.5,y=y+.5},direction=y==top and side.inward or 0};id=id+1
  end
 end
 for i=#es,first,-1 do if remove[es[i]]then table.remove(es,i)end end
 meta.offset_x=meta.offset_x-1;meta.width=meta.width+2;meta.input_loops=2
 return id,2
end
return M
