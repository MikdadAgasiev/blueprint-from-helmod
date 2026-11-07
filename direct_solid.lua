-- Direct construction of compact solid blocks. No placeholder inserters.
local M={}
local transfer=require('transfer')
local capacity=require('capacity')
function M.build(r,settings,name,count,ox,oy,en,list,catalog,force,header,beacon_width)
 if settings.transfer_mode~='loaders' and settings.transfer_mode~='auto' then return end
 local proto=prototypes.entity[name];local W,H=proto.tile_width,proto.tile_height
 if W<2 or H<2 then return end
 local ingredients,products={},{}
 for _,v in ipairs(r.ingredients or {}) do if v.type=='fluid' then return end;ingredients[#ingredients+1]=v end
 for _,v in ipairs(r.products or {}) do if v.type=='fluid' then return end;products[#products+1]=v.name end
 if #ingredients<1 or #ingredients>2 or #products~=1 then return end
 if #ingredients==2 and count>1 then for _,v in ipairs(ingredients) do if capacity.flow(v,r)*math.ceil(count/2)/count>capacity.belt(settings.belt_in)/2+1e-8 then return end end end
 local function choose(belt,names,side,arm,required)
  local demand=required or 0
  if not required then for _,v in ipairs(side=='input' and ingredients or r.products) do demand=demand+capacity.flow(v,r)/count end end
  if transfer.rate(arm,force,belt,names,side)+1e-8>=demand then return arm,false end
  local selected
  for _,n in ipairs(catalog.loaders) do
   if (not settings.loader_name or settings.loader_name=='auto' or settings.loader_name==n) and transfer.rate(n,force,belt,names,side)+1e-8>=demand then
    if not selected or prototypes.entity[n].belt_speed<prototypes.entity[selected].belt_speed then selected=n end
   end
  end
  if selected then return selected,true end
 end
 if count==1 then
  local devices,names={},{};local any_loader=false
  for i,v in ipairs(ingredients) do
   local n,loader=choose(settings.belt_in,{v.name},'input',settings.inserter_in,capacity.flow(v,r))
   if not n then return end;devices[i]={name=n,loader=loader};names[i]=v.name;any_loader=any_loader or loader
  end
  local output,loader=choose(settings.belt_out,products,'output',settings.inserter_out)
  if not output or not (any_loader or loader) then return end
  local my=#ingredients==2 and 2 or 0;local sy=my+H-1;local width=W+4
  local function add(n,x,y,w,h,d,extra)
   local e={entity_number=en,name=n,position={x=ox+x+w/2,y=oy+y+h/2},direction=d or 0};en=en+1
   for k,v in pairs(extra or {}) do e[k]=v end;list[#list+1]=e
  end
  add(name,2,my,W,H,0,{recipe=r.name})
  add(settings.belt_in,0,sy,1,1,4)
  add(devices[1].name,1,sy,1,1,devices[1].loader and 4 or 12,devices[1].loader and {type='input'} or nil)
  local inputs={{x=ox,y=oy+sy,ingredient=names[1],direction=4}}
  if devices[2] then
   local x=2+math.floor(W/2)
   add(settings.belt_in,x,0,1,1,8)
   add(devices[2].name,x,1,1,1,devices[2].loader and 8 or 0,devices[2].loader and {type='input'} or nil)
   inputs[2]={x=ox+x,y=oy,ingredient=names[2],direction=8}
  end
  add(output,W+2,sy,1,1,loader and 4 or 12,loader and {type='output'} or nil)
  add(settings.belt_out,W+3,sy,1,1,4)
  return en,my+H,{offset_x=ox,offset_y=oy,width=width,height=my+H,ingredients=names,products=products,inputs=inputs,product_out={x=ox+W+3,y=oy+sy,direction=4},direct_equipment=true,is_single_assembler_block=true}
 end
 local names={};for _,v in ipairs(ingredients) do names[#names+1]=v.name end
 local input,il=choose(settings.belt_in,names,'input',settings.inserter_in)
 local output,ol=choose(settings.belt_out,products,'output',settings.inserter_out)
 if not input or not output then return end
 local splitter
 for _,n in ipairs(catalog.splitters) do if prototypes.entity[n].belt_speed>=prototypes.entity[settings.belt_in].belt_speed and (not splitter or prototypes.entity[n].belt_speed<prototypes.entity[splitter].belt_speed) then splitter=n end end
 if not splitter then return end
 -- A single contiguous machine bank avoids the empty centre of a paired
 -- block when all required material fits on its one-sided transfer lanes.
 -- A 2x2 loader tap needs the header row; ordinary and taller banks do not.
 local single_top=(il and H==2) and 1 or 0
 local single_width=W+(#ingredients==2 and 5 or 4)+(il and 1 or 0)
 local paired_width=2*W+9
 local paired_top=#ingredients==1 and 3 or math.max(3,6-H)
 local single_fits=single_width*(single_top+count*H)<paired_width*(paired_top+math.ceil(count/2)*H+1)
 -- A vertical list benefits from a shorter bank even when it is wider.
 if settings.link_mode=='independent' and single_top+count*H>paired_top+math.ceil(count/2)*H+1 then single_fits=false end
 local out_rate=0;for _,v in ipairs(r.products) do out_rate=out_rate+capacity.flow(v,r) end
 if out_rate>capacity.belt(settings.belt_out)/2+1e-8 then single_fits=false end
 for _,v in ipairs(ingredients) do if capacity.flow(v,r)>capacity.belt(settings.belt_in)/(#ingredients==2 and 2 or 1)+1e-8 then single_fits=false end end
 if single_fits and not beacon_width then
  local trunk=#ingredients==2 and 1 or 0;local mx=trunk+(il and 3 or 2);local outx=mx+W+1
  local height=single_top+count*H
  local function add(n,x,y,w,h,d,extra)
   local e={entity_number=en,name=n,position={x=ox+x+w/2,y=oy+y+h/2},direction=d or 0};en=en+1
   for k,v in pairs(extra or {}) do e[k]=v end;list[#list+1]=e
  end
  local inputs
  if #ingredients==2 then
   add(settings.belt_in,0,0,1,1,4);add(settings.belt_in,1,0,1,1,8);add(settings.belt_in,2,0,1,1,12)
   inputs={{x=ox,y=oy,ingredient=names[1],direction=4},{x=ox+2,y=oy,ingredient=names[2],direction=12}}
  else inputs={{x=ox,y=oy,ingredient=names[1],direction=8}};if single_top>0 then add(settings.belt_in,0,0,1,1,8) end end
  for row=0,count-1 do local y=single_top+row*H;local feed=y+H-1
   add(name,mx,y,W,H,0,{recipe=r.name})
   for yy=y,feed do
    if il and row<count-1 and yy==feed-1 then add(splitter,trunk,yy,2,1,8)
    -- The mixed-feed header already owns the trunk cell at y=0.
    elseif not (#ingredients==2 and yy==0) then add(settings.belt_in,trunk,yy,1,1,il and row==count-1 and yy==feed and 4 or 8) end
   end
   if il then add(settings.belt_in,trunk+1,feed,1,1,4) end
   add(input,mx-1,feed,1,1,il and 4 or 12,il and {type='input'} or nil)
   add(output,mx+W,feed,1,1,ol and 4 or 12,ol and {type='output'} or nil)
  end
  for y=single_top+H-1,height-1 do add(settings.belt_out,outx,y,1,1,8) end
  return en,height,{offset_x=ox,offset_y=oy,width=single_width,height=height,ingredients=names,products=products,inputs=inputs,product_out={x=ox+outx,y=oy+height-1,direction=8},direct_equipment=true,single_bank=true}
 end
 if not (il or ol or beacon_width) then return end
 local outgoing=0;for _,v in ipairs(r.products) do outgoing=outgoing+capacity.flow(v,r) end
 local balance=count%2==1 and outgoing*math.ceil(count/2)/count>capacity.belt(settings.belt_out)/2+1e-8
 if balance and beacon_width then return end
 local output_splitter,output_ug
 if balance then
  output_ug=settings.belt_out:gsub('transport%-belt','underground-belt')
  local p=prototypes.entity[output_ug]
  if not p or p.type~='underground-belt' or p.belt_speed<prototypes.entity[settings.belt_out].belt_speed or p.max_underground_distance<2 then return end
  for _,n in ipairs(catalog.splitters) do if prototypes.entity[n].belt_speed>=prototypes.entity[settings.belt_out].belt_speed and (not output_splitter or prototypes.entity[n].belt_speed<prototypes.entity[output_splitter].belt_speed) then output_splitter=n end end
  if not output_splitter then return end
 end
 -- Two facing banks leave a central bay for the beacon. The collectors
 -- run beside the bay and merge below the last machines.
 local width=2*W+9+(beacon_width and beacon_width+1 or 0);local rows=math.ceil(count/2);local top=#ingredients==1 and 3 or math.max(3,6-H)
 local function add(n,x,y,w,h,d,extra)
  local e={entity_number=en,name=n,position={x=ox+x+w/2,y=oy+y+h/2},direction=d or 0};en=en+1
  for k,v in pairs(extra or {}) do e[k]=v end;list[#list+1]=e
 end
 en=header(#ingredients,width,settings.belt_in,ox,oy,en,list)
 -- Header's last feeder cells are at y=2. Extend them to the body.
 for y=3,top-1 do add(settings.belt_in,0,y,1,1,8);add(settings.belt_in,width-1,y,1,1,8) end
 local center=math.floor(width/2)
 if not beacon_width then
 for y=top+H-1,top+rows*H-(balance and 0 or 1) do add(settings.belt_out,center,y,1,1,8) end
 end
 for side=0,1 do
  local machines=side==0 and math.ceil(count/2) or math.floor(count/2)
  local outer=side==0 and 0 or width-1;local branch=side==0 and 1 or width-2
  local loading=side==0 and 2 or width-3;local mx=side==0 and 3 or width-3-W
  local unloading=side==0 and mx+W or mx-1
  local flow=side==0 and 4 or 12
  for row=0,machines-1 do
   local y=top+row*H;local feed=y+H-1
   add(name,mx,y,W,H,0,{recipe=r.name})
   for yy=y,feed do
    if row<machines-1 and yy==feed-1 then add(splitter,side==0 and outer or branch,yy,2,1,8)
    else add(settings.belt_in,outer,yy,1,1,row==machines-1 and yy==feed and flow or 8) end
   end
   add(settings.belt_in,branch,feed,1,1,flow)
   add(input,loading,feed,1,1,il and flow or (flow+8)%16,il and {type='input'} or nil)
   if not (balance and side==0 and row==rows-1) then add(output,unloading,feed,1,1,ol and flow or (flow+8)%16,ol and {type='output'} or nil) end
  end
  if beacon_width then
   local collector=unloading+(side==0 and 1 or -1)
   for y=top+H-1,top+rows*H-1 do add(settings.belt_out,collector,y,1,1,8) end
   if side==0 then
    for x=collector,center-1 do add(settings.belt_out,x,top+rows*H,1,1,4) end
   else
    for x=center+1,collector do add(settings.belt_out,x,top+rows*H,1,1,12) end
   end
  end
 end
 local inputs={};local split=math.floor((width-1)/2)-1
 for i,n in ipairs(names) do inputs[i]={x=ox+split+(i-1)*2,y=oy,ingredient=n} end
 -- The last unloading row is already a real outlet; no trailing row is needed.
 local bottom=top+rows*H-(balance and 0 or 1)
 if beacon_width then
  bottom=top+rows*H
  add(settings.belt_out,center,bottom,1,1,8)
  bottom=bottom+1
  add(settings.belt_out,center,bottom,1,1,8)
 elseif balance then
  local y=bottom-1;local x=W+2
  add(output,x,y+1,1,1,ol and 8 or 0,ol and {type='output'} or nil)
  add(settings.belt_out,x,y+2,1,1,8)
  add(output_splitter,x,y+3,2,1,8)
  add(settings.belt_out,x,y+4,1,1,8)
  add(settings.belt_out,x+1,y+4,1,1,4)
  add(settings.belt_out,x,y+5,1,1,4)
  add(output_ug,x+1,y+5,1,1,4,{type='input'})
  add(output_ug,x+3,y+5,1,1,4,{type='output'})
  add(settings.belt_out,x+4,y+5,1,1,0)
  add(settings.belt_out,x+4,y+4,1,1,12)
  add(settings.belt_out,x+3,y+4,1,1,12)
  for yy=y+2,y+6 do add(settings.belt_out,center,yy,1,1,8) end
  bottom=y+6
 end
 return en,bottom+1,{offset_x=ox,offset_y=oy,width=width,height=bottom+1,ingredients=names,products=products,inputs=inputs,product_out={x=ox+center,y=oy+bottom},direct_equipment=true}
end
return M
