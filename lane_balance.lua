local M={}
local capacity=require('capacity')
local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
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
