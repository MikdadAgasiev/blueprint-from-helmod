local M={}
local resources=require('resources')
local capacity=require('capacity')
local work=require('generation_work')
function M.encode(recipes)
 local result=work.copy(recipes)
 for _,r in ipairs(result) do
  r.quality=resources.quality(r.quality)
  for _,field in ipairs({'ingredients','products'}) do
   if r[field]==nil then
    r[field]={}
    local prototype=prototypes.recipe[r.name]
    for _,v in ipairs(prototype and prototype[field] or {}) do
     r[field][#r[field]+1]={name=v.name,type=v.type,amount=v.amount}
    end
   end
   local seen={}
   for i,v in ipairs(r[field] or {}) do if v.type~='fluid' then
    local q=v.quality
    if not q then
     local p=prototypes.recipe[r.name]
     local getter=field=='ingredients' and p and p.get_ingredient_quality or p and p.get_product_quality
     local index
     for j,raw in ipairs(p and p[field] or {}) do if raw.name==v.name then index=j;break end end
     q=getter and index and getter(index,r.quality) or r.quality
    end
    v.quality=resources.quality(q)
    if not prototypes.quality[v.quality] then error({'bfh.plan-equipment-invalid',v.quality},0) end
    v.name=resources.key(v.name,v.quality)
    if field=='ingredients' then
     local base=resources.name(v.name)
     if seen[base] and seen[base]~=v.name then error({'bfh.quality-mixed-ingredient',base},0) end
     seen[base]=v.name
    end
   end end
   -- Recipes may list a catalyst and another result as separate entries of
   -- the same item/grade. They still need one physical sorting branch.
   local merged,by_key={},{}
   for _,v in ipairs(r[field] or {}) do
    local key=(v.type or 'item')..'/'..v.name;local prior=by_key[key]
    if prior then
     local period=tonumber(r.base_time) or 1;if period<=0 then period=1 end
     prior.count=(capacity.flow(prior,r)+capacity.flow(v,r))*period;prior.amount=nil
    else by_key[key]=v;merged[#merged+1]=v end
   end
   r[field]=merged
  end
 end
 return result
end
-- One physical output belt/device carries every grade before sorting.
function M.physical(r)
 local result={};for k,v in pairs(r) do result[k]=v end
 result.base_time=1;result.count=nil
 result.quality_outputs=0;for _,v in ipairs(r.products or {}) do if v.type~='fluid' then result.quality_outputs=result.quality_outputs+1 end end
 for _,field in ipairs({'ingredients','products'}) do
  result[field]={};local groups={}
  for _,v in ipairs(r[field] or {}) do
   local name=resources.name(v.name);local k=(v.type or 'item')..'/'..name
   if not groups[k] then groups[k]={name=name,type=v.type or 'item',count=0};result[field][#result[field]+1]=groups[k] end
   groups[k].count=groups[k].count+capacity.flow(v,r)
  end
 end
 return result
end
function M.metadata(meta,r)
 local inputs={}
 for _,v in ipairs(r.ingredients or {}) do if v.type~='fluid' then inputs[resources.name(v.name)]=v.name end end
 for _,p in ipairs(meta.inputs or {}) do p.ingredient=inputs[p.ingredient] or p.ingredient end
 meta.ingredients={};for _,v in ipairs(r.ingredients or {}) do if v.type~='fluid' then meta.ingredients[#meta.ingredients+1]=v.name end end
 meta.products={};for _,v in ipairs(r.products or {}) do if v.type~='fluid' then meta.products[#meta.products+1]=v.name end end
 meta.recipe_node=r
end
function M.sort(entities,first,meta,r,settings,en,catalog)
 if not meta.product_out or #meta.products<2 then return en end
 local splitter
 for _,name in ipairs(catalog.splitters) do
  if capacity.belt(name)+1e-8>=capacity.belt(settings.belt_out) and (not splitter or capacity.belt(name)<capacity.belt(splitter)) then splitter=name end
 end
 if not splitter then error({'bfh.quality-no-splitter'},0) end
 local source=meta.product_out;local turn=((source.direction or 8)-8)/4%4
 local function point(x,y)
  for _=1,turn do x,y=-y,x end
  return source.x+x,source.y+y
 end
 local function add(name,x,y,w,h,d,extra)
  local cx,cy=x+w/2-.5,y+h/2-.5
  local px,py=point(cx,cy)
  local e={entity_number=en,name=name,position={x=px+.5,y=py+.5},direction=(d+turn*4)%16};en=en+1
  for k,v in pairs(extra or {}) do e[k]=v end
  entities[#entities+1]=e
 end
 -- Legacy templates expose the first routable cell just beyond their last
 -- output belt. A collector normally fills it; a sorter must do so itself.
 local occupied=false
 for j=first,#entities do local e=entities[j]
  if math.floor(e.position.x)==source.x and math.floor(e.position.y)==source.y then occupied=true;break end
 end
 if not occupied then add(settings.belt_out,0,0,1,1,8) end
 meta.mixed_output={x=source.x,y=source.y,direction=source.direction or 8};meta.product_outs={}
 local lead=0
 for _,b in ipairs(r.beacons or (r.beacon and {r.beacon}) or {}) do if (tonumber(b.combo) or 0)>0 then
  local p=prototypes.entity[b.name]
  lead=math.max(lead,(p.get_supply_area_distance(resources.quality(b.quality)) or 0)+p.tile_width+p.tile_height+4)
 end end
 for y=1,lead do add(settings.belt_out,0,y,1,1,8) end
 for i,key in ipairs(meta.products) do
  local x,y=i-1,2*i-1+lead
  add(splitter,x,y,2,1,8,{filter=resources.filter(key),output_priority='right'})
  add(settings.belt_out,x,y+1,1,1,12)
  add(settings.belt_out,x-1,y+1,1,1,12)
  local px,py=point(x-1,y+1)
  meta.product_outs[key]={x=px,y=py,direction=(12+turn*4)%16}
  if i<#meta.products then add(settings.belt_out,x+1,y+1,1,1,8) end
 end
 local p=meta.product_outs[meta.products[1]]
 meta.product_out={x=p.x,y=p.y,direction=p.direction}
 return en
end
function M.fit(entities,first,meta)
 if not meta.product_outs then return end
 local left,top=meta.offset_x,meta.offset_y
 local right,bottom=left+(meta.width or 0),top+(meta.height or 0)
 for j=first,#entities do local e=entities[j];local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if e.direction==4 or e.direction==12 then w,h=h,w end
  left=math.min(left,e.position.x-w/2);top=math.min(top,e.position.y-h/2)
  right=math.max(right,e.position.x+w/2);bottom=math.max(bottom,e.position.y+h/2)
 end
 local dx,dy=meta.offset_x-left,meta.offset_y-top
 for j=first,#entities do local e=entities[j];e.position.x=e.position.x+dx;e.position.y=e.position.y+dy end
 local function move(p)if p then p.x=p.x+dx;p.y=p.y+dy end end
 for _,p in ipairs(meta.inputs or {}) do move(p) end
 move(meta.product_out);move(meta.mixed_output)
 for _,p in pairs(meta.product_outs) do move(p) end
 meta.width=right-left;meta.height=bottom-top
 if meta.protected_bounds then
  meta.protected_bounds={left=meta.offset_x,top=meta.offset_y,right=meta.offset_x+meta.width,bottom=meta.offset_y+meta.height}
 end
end
return M
