-- Three solid ingredients: two outer mixed feeds and a separate central feed.
-- Transfer devices and crossings are planned before block placement.
local M={}
local transfer=require('transfer')
local capacity=require('capacity')
function M.build(r,s,name,count,ox,oy,en,list,catalog,force,header)
 if s.transfer_mode~='loaders' and s.transfer_mode~='auto' then return end
 local p=prototypes.entity[name];local W,H=p.tile_width,p.tile_height
 if W<3 or H<3 or #(r.ingredients or {})~=3 or #(r.products or {})~=1 then return end
 for _,side in ipairs({'ingredients','products'}) do for _,v in ipairs(r[side]) do if v.type=='fluid' then return end end end
 local names={};for i,v in ipairs(r.ingredients) do names[i]=v.name end
 local function choose(belt,items,side,arm,demand)
  local selected,loader=transfer.single_device(s,catalog,force,belt,items,side,arm,demand)
  if selected then return {name=selected,loader=loader} end
 end
 local pair=capacity.flow(r.ingredients[1],r)/count+capacity.flow(r.ingredients[2],r)/count
 local a=choose(s.belt_in,{names[1],names[2]},'input',s.inserter_in,pair)
 local b=choose(s.belt_in,{names[3]},'input',s.inserter_in,capacity.flow(r.ingredients[3],r)/count)
 local c=choose(s.belt_out,{r.products[1].name},'output',s.inserter_out,capacity.flow(r.products[1],r)/count)
 if not a or not b or not c then return end
 -- Odd banks need an independent third feed all the way to the unpaired machine.
 if not (a.loader or b.loader or c.loader or (s.transfer_mode=='auto' and count>1 and count%2==1)) then return end
 local function underground(belt)
  local p=prototypes.entity[belt];local related=p and p.related_underground_belt
  return related and related.name or belt:gsub('transport%-belt','underground-belt')
 end
 local function researched(name)
  local p=prototypes.entity[name]
  for _,item in pairs(p and p.items_to_place_this or {}) do if (catalog.items or {})[item.name]==name then return true end end
  return false
 end
 local ug=underground(s.belt_in)
 local up=prototypes.entity[ug]
 if not researched(ug) or not up or up.type~='underground-belt' or up.max_underground_distance<5 then return end
 local split
 for _,n in ipairs(catalog.splitters) do if capacity.belt(n)>=capacity.belt(s.belt_in) and (not split or capacity.belt(n)<capacity.belt(split)) then split=n end end
 if not split then return end
 local outug=underground(s.belt_out)
 local outp=prototypes.entity[outug];if not researched(outug) or not outp or outp.type~='underground-belt' or outp.max_underground_distance<3 then return end
 local width=2*W+15;local top=6;local rows=math.ceil(count/2);local bottom=top+rows*H
 local trunk=W+5;local third=W+8
 local function add(n,x,y,w,h,d,extra)
  local e={entity_number=en,name=n,position={x=ox+x+w/2,y=oy+y+h/2},direction=d or 0};en=en+1
  for k,v in pairs(extra or {}) do e[k]=v end;list[#list+1]=e
 end
 local function belt(n,x,y,d) add(n,x,y,1,1,d) end
 local function device(config,x,y,flow,side)
  add(config.name,x,y,1,1,config.loader and flow or (flow+8)%16,config.loader and {type=side} or nil)
 end
 en=header(2,width,s.belt_in,ox,oy,en,list)
 for y=3,top-1 do belt(s.belt_in,0,y,8);belt(s.belt_in,width-1,y,8) end
 -- The third feed crosses the header underground, with an accessible mouth.
 local entry=third+2
 belt(s.belt_in,entry,-3,8);add(ug,entry,-2,1,1,8,{type='input'});add(ug,entry,3,1,1,8,{type='output'})
 belt(s.belt_in,entry,4,8);belt(s.belt_in,entry,5,12);belt(s.belt_in,entry-1,5,12);belt(s.belt_in,third,5,8)
 for y=6,bottom do belt(s.belt_in,third,y,8) end
 for y=(count>1 and top or top+H-1),bottom do belt(s.belt_out,trunk,y,8) end
 local function remove_belt(n,x,y)
  for i=#list,1,-1 do local e=list[i];if e.name==n and math.floor(e.position.x)==ox+x and math.floor(e.position.y)==oy+y then table.remove(list,i);return end end
 end
 for side=0,1 do
  local n=side==0 and rows or math.floor(count/2)
  local outer=side==0 and 0 or width-1;local branch=side==0 and 1 or width-2
  local mx=side==0 and 3 or W+12;local loading=side==0 and 2 or width-3
  local flow=side==0 and 4 or 12;local inner=side==0 and mx+W or mx-1
  for row=0,n-1 do
   local y=top+row*H;local feed=y+H-1
   add(name,mx,y,W,H,0,{recipe=r.name})
   for yy=y,feed do
    if row<n-1 and yy==feed-1 then add(split,math.min(outer,branch),yy,2,1,8)
    else belt(s.belt_in,outer,yy,row==n-1 and yy==feed and flow or 8) end
   end
   belt(s.belt_in,branch,feed,flow);device(a,loading,feed,flow,'input')
   local fy=y+(side==0 and 1 or 2)
   remove_belt(s.belt_in,third,fy-1)
   local terminal=row==rows-1 and (side==1 or count%2==1)
   if terminal then
    belt(s.belt_in,third,fy-1,side==0 and 12 or 4)
    belt(s.belt_in,third+(side==0 and -1 or 1),fy-1,8)
    for yy=fy,bottom do remove_belt(s.belt_in,third,yy) end
   else add(split,side==0 and third-1 or third,fy-1,2,1,8) end
   if side==0 then
    belt(s.belt_in,third-1,fy,12)
    add(ug,third-2,fy,1,1,12,{type='input'});add(ug,trunk-1,fy,1,1,12,{type='output'})
    device(b,inner,fy,12,'input')
    device(c,inner,feed,4,'output');belt(s.belt_out,inner+1,feed,4)
   else
    belt(s.belt_in,third+1,fy,4);belt(s.belt_in,third+2,fy,4);device(b,inner,fy,4,'input')
    device(c,inner,y,12,'output');belt(s.belt_out,inner-1,y,12)
    add(outug,inner-2,y,1,1,12,{type='input'});add(outug,trunk+1,y,1,1,12,{type='output'})
   end
  end
 end
 local middle=math.floor((width-1)/2)-1
 local inputs={{x=ox+middle,y=oy,ingredient=names[1],direction=8},{x=ox+middle+2,y=oy,ingredient=names[2],direction=8},{x=ox+entry,y=oy-3,ingredient=names[3],direction=8}}
 return en,bottom+1,{offset_x=ox,offset_y=oy,width=width,height=bottom+1,ingredients=names,products={r.products[1].name},inputs=inputs,product_out={x=ox+trunk,y=oy+bottom,direction=8},direct_equipment=true,is_single_assembler_block=true}
end
return M
