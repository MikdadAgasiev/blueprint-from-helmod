-- Low-rate multi-input machines: paired lanes with independently fed faces.
local M={}
local transfer=require('transfer')
local capacity=require('capacity')
function M.build(r,s,name,count,ox,oy,en,entities,catalog,force,input_ug,output_ug)
 local p=prototypes.entity[name];local W,H=p.tile_width,p.tile_height;local n=#(r.ingredients or {})
 if W<3 or H<3 or n<5 or n>7 or #(r.products or {})~=1 then return end
 for _,side in ipairs({'ingredients','products'}) do for _,v in ipairs(r[side]) do if v.type=='fluid' then return end end end
 local long='long-handed-inserter';if not catalog.available[long] then return end
 local complex=n>=7
 if n>=6 and (not prototypes.entity[input_ug] or (prototypes.entity[input_ug].max_underground_distance or 0)<(complex and W or 2)) then return end
 if complex and (not prototypes.entity[output_ug] or (prototypes.entity[output_ug].max_underground_distance or 0)<3) then return end
 local names={};for i,v in ipairs(r.ingredients) do names[i]=v.name end
 local function demand(a,b)
  local rate=0;for i=a,math.min(n,b) do rate=rate+capacity.flow(r.ingredients[i],r)/count end;return rate
 end
 local function enough(a,b)
  local items={};for i=a,math.min(n,b) do items[#items+1]=names[i] end
  return transfer.rate(long,force,s.belt_in,items,'input')*.8+1e-8>=demand(a,b)
 end
 if not enough(5,6) or not enough(complex and 7 or 3,complex and 8 or 4) then return end
 local function choose(belt,items,side,selected,required)
  local device,loader=transfer.single_device(s,catalog,force,belt,items,side,selected,required)
  if not loader then return device end
 end
 local input=choose(s.belt_in,{names[1],names[2]},'input',s.inserter_in,demand(1,2))
 local input_bottom=complex and choose(s.belt_in,{names[3],names[4]},'input',s.inserter_in,demand(3,4)) or long
 local output=choose(s.belt_out,{r.products[1].name},'output',s.inserter_out,capacity.flow(r.products[1],r)/count)
 if not input or not input_bottom or not output then return end
 local stride=W+(complex and 2 or 0);local width=5+stride*count
 local cy=H+(complex and 4 or 5);local product_y=H+(complex and 8 or 4)
 local height=H+(complex and 11 or 9)
 local function add(n,x,y,w,h,d,extra)
  local e={entity_number=en,name=n,position={x=ox+x+w/2,y=oy+2+y+h/2},direction=d or 0};en=en+1
  for k,v in pairs(extra or {}) do e[k]=v end;entities[#entities+1]=e
 end
 local inputs={}
 local function feed(i,row,turnx,end_y,d)
  for x=0,turnx-1 do add(s.belt_in,x,row,1,1,4) end
  local step=d==8 and 1 or -1
  for y=row,end_y,step do add(s.belt_in,turnx,y,1,1,d) end
  inputs[i]={x=ox,y=oy+2+row,direction=4,ingredient=names[i]}
 end
 feed(1,0,2,0,8);feed(2,2,2,2,0)
 feed(3,cy-1,2,cy-1,8);feed(4,cy+1,2,cy+1,0)
 feed(5,-2,4,-1,8)
 if n>=6 then feed(6,4,4,1,0) end
 if complex then feed(7,H+8,4,H+6,0) end
 for x=2,width-1 do
  if n<6 or x<3 or x>5 then add(s.belt_in,x,1,1,1,4) end
 end
 if n>=6 then add(input_ug,3,1,1,1,4,{type='input'});add(input_ug,5,1,1,1,4,{type='output'}) end
 for x=4,width-1 do add(s.belt_in,x,0,1,1,4) end
 if complex then
  for x=2,4 do add(s.belt_in,x,cy,1,1,4) end
  for x=4,width-1 do add(s.belt_in,x,H+5,1,1,4) end
 else for x=2,width-W do add(s.belt_in,x,cy,1,1,4) end end
 for x=5+W-1,width-1 do add(s.belt_out,x,product_y,1,1,4) end
 for i=0,count-1 do
  local x=5+stride*i;local fixed=p.fixed_recipe
  add(name,x,3,W,H,0,{recipe=fixed and fixed.name or r.name})
  add(input,x,2,1,1,0);add(long,x+W-1,2,1,1,0)
  add(input_bottom,x,H+3,1,1,8)
  if complex then
   add(long,x+1,H+3,1,1,8)
   add(input_ug,x,cy,1,1,4,{type='input'})
   add(input_ug,x+W,cy,1,1,4,{type='output'})
   if i<count-1 then add(s.belt_in,x+W+1,cy,1,1,4) end
   add(output_ug,x+W-1,H+4,1,1,8,{type='input'})
   add(output_ug,x+W-1,H+7,1,1,8,{type='output'})
  end
  add(output,x+W-1,H+3,1,1,0)
 end
 return en,height,{offset_x=ox,offset_y=oy,width=width,height=height,ingredients=names,
  products={r.products[1].name},inputs=inputs,product_out={x=ox+width-1,y=oy+2+product_y,direction=4},direct_equipment=true}
end
return M
