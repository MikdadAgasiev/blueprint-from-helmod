-- Local collection keeps complete belt lanes: joins use splitters, never side-loading.
local M={}
local capacity=require('capacity')
local containers=require('container_distribution')
local orientation=require('orientation')
function M.prepare(entities,blocks,indices,extras,occupied,settings,id,catalog)
 local ports,total,name={},0,nil
 for _,bi in ipairs(indices) do local b=blocks[bi];local r=b.recipe_node;local p=b.product_out
  if not p or b.output_ports or b.product_outs or #(r.products or {})~=1 then return id,false end
  local v=r.products[1];local rate=capacity.flow(v,r)
  if v.type=='fluid' or rate<=0 or (name and name~=v.name) or (ports[1] and p.y~=ports[1].y) then return id,false end
  name=v.name;ports[#ports+1]={x=p.x,y=p.y,rate=rate,block=bi};total=total+rate
 end
 local speed=capacity.belt(settings.belt_out);local count=#ports
 local n=math.ceil(total/speed-1e-9)
 local context
 if settings.distribution_mode=='containers' then
  local cs={};for k,v in pairs(settings) do cs[k]=v end;cs.belt_in=settings.belt_out
  context=containers.context(cs)
  for _,p in ipairs(ports) do if p.rate>context.capacity+1e-8 then return id,false end end
  n=math.ceil(total/context.capacity-1e-9)
  if not containers.select(context,count,n) then return id,false end
 elseif n>=count or n>2 or count>3 then return id,false end
 local split
 if not context then
  for _,s in ipairs(catalog.splitters or {}) do local p=prototypes.entity[s]
   if p.belt_speed>=prototypes.entity[settings.belt_out].belt_speed and (not split or p.belt_speed<prototypes.entity[split].belt_speed) then split=s end
  end
  if not split then return id,false end
 end
 local pending,cells,outlets={}, {},{}
 local function add(name,x,y,d,w,h,kind)
  for xx=x,x+(w or 1)-1 do for yy=y,y+(h or 1)-1 do
   local k=xx..','..yy;if cells[k] or occupied[k] then return false end
  end end
  pending[#pending+1]={entity_number=id+#pending,name=name,position={x=x+(w or 1)/2,y=y+(h or 1)/2},direction=d,type=kind}
  for xx=x,x+(w or 1)-1 do for yy=y,y+(h or 1)-1 do cells[xx..','..yy]=true end end
  return true
 end
 local function belt(x,y,d)return add(settings.belt_out,x,y,d) end
 local y=ports[1].y
 -- Materialize empty original ports; existing aligned ends remain with their bank.
 for _,p in ipairs(ports) do if not occupied[p.x..','..p.y] and not belt(p.x,p.y,8) then return id,false end end
 if context then
  local cs={belt_in=settings.belt_out};local es={}
  local ins,outs,_,nextid=containers.emit(es,1,context,cs,count,n,0,0,name)
  for _,e in ipairs(es) do orientation.entity(e,1) end
  for _,p in ipairs(ins) do orientation.port(p,1) end
  for _,p in ipairs(outs) do orientation.port(p,1) end
  table.sort(ins,function(a,b)return a.x<b.x end)
  local maxx,top=-math.huge,math.huge
  for _,p in ipairs(ins) do maxx=math.max(maxx,p.x);top=math.min(top,p.y) end
  local dx,dy=ports[1].x-2-maxx,y+count+3-top
  for _,e in ipairs(es) do local proto=prototypes.entity[e.name];local w,h=proto.tile_width,proto.tile_height
   if (e.direction or 0)%8==4 then w,h=h,w end
   if not add(e.name,math.floor(e.position.x+dx-w/2+.001),math.floor(e.position.y+dy-h/2+.001),e.direction,w,h,e.type) then return id,false end
   pending[#pending].filters=e.filters;pending[#pending].filter_mode=e.filter_mode
  end
  for i,p in ipairs(ports) do local target=ins[i];target.x=target.x+dx;target.y=target.y+dy
   local row=y+i
   for yy=y+1,row-1 do if not belt(p.x,yy,8) then return id,false end end
   if not belt(p.x,row,12) then return id,false end
   for x=p.x-1,target.x+1,-1 do if not belt(x,row,12) then return id,false end end
   for yy=row,target.y-1 do if not belt(target.x,yy,8) then return id,false end end
  end
  for _,p in ipairs(outs) do outlets[#outlets+1]={x=p.x+dx,y=p.y+dy,direction=8,share=total/n/ports[1].rate} end
 elseif n==1 then
  local x=ports[1].x;local last=y+2+3*(count-1)
  for yy=y+1,last+2 do
   local merge=false;for j=2,count do if yy==y+3+3*(j-1) then merge=true end end
   if merge then if not add(split,x,yy,8,2,1) then return id,false end
   elseif not belt(x,yy,8) then return id,false end
  end
  for j=2,count do local p=ports[j];local row=y+2+3*(j-1)
   for yy=y+1,row-1 do if not belt(p.x,yy,8) then return id,false end end
   for xx=p.x,x+2,-1 do if not belt(xx,row,12) then return id,false end end
   if not belt(x+1,row,8) then return id,false end
  end
  outlets[1]={x=x,y=last+2,direction=8,share=total/ports[1].rate}
 else
  -- Three equal-capacity banks can feed two full-width exits through a central split.
  local a,b,c=ports[1],ports[2],ports[3]
  if a.rate+b.rate/2>speed+1e-8 or c.rate+b.rate/2>speed+1e-8 then return id,false end
  for yy=y+1,y+4 do if not belt(a.x,yy,8) then return id,false end end
  for yy=y+1,y+2 do if not belt(b.x,yy,8) then return id,false end end
  if not add(split,b.x-1,y+3,8,2,1) then return id,false end
  for xx=b.x-1,a.x+2,-1 do if not belt(xx,y+4,12) then return id,false end end
  if not belt(a.x+1,y+4,8) or not add(split,a.x,y+5,8,2,1) then return id,false end
  for yy=y+6,y+10 do if not belt(a.x,yy,8) then return id,false end end
  for yy=y+4,y+6 do if not belt(b.x,yy,8) then return id,false end end
  for xx=b.x,c.x-2 do if not belt(xx,y+7,4) then return id,false end end
  if not belt(c.x-1,y+7,8) then return id,false end
  for yy=y+1,y+7 do if not belt(c.x,yy,8) then return id,false end end
  if not add(split,c.x-1,y+8,8,2,1) then return id,false end
  for yy=y+9,y+10 do if not belt(c.x,yy,8) then return id,false end end
  outlets={{x=a.x,y=y+10,direction=8,share=(a.rate+b.rate/2)/a.rate},{x=c.x,y=y+10,direction=8,share=(c.rate+b.rate/2)/a.rate}}
 end
 local owner=indices[1];local list=extras[owner] or {};extras[owner]=list
 for _,e in ipairs(pending) do list[#list+1]=e end
 for k in pairs(cells) do occupied[k]=true end
 for _,p in ipairs(ports) do local b=blocks[p.block]
  b.array_output_contacts={{x=p.x,y=p.y+(cells[p.x..','..p.y] and 0 or 1),owner=owner,direction=8}}
  b.product_out=nil
 end
 local first=blocks[owner];first.output_ports=outlets
 first.product_out={x=outlets[1].x,y=outlets[1].y,direction=8}
 return id+#pending,true
end
return M
