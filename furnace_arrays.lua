-- Keep compatible furnace sections adjacent while preserving each section's flow.
local M={}
local capacity=require('capacity')
local resources=require('resources')
local contacts=require('belt_contacts')
local array_outputs=require('array_outputs')
local hierarchy=require('hierarchy')
local function groups_for(blocks,limit)
 local groups,by_key={},{}
 for i,b in ipairs(blocks) do
  local tag=b.production_group or b.furnace_array
  local count=((b.recipe_node or {}).factory or {}).count
  if tag and count then tag=tostring(tag)..'/'..tostring(count) end
  local group=tag and by_key[tag]
  if not group or #group>=(limit or 3) then group={};groups[#groups+1]=group;if tag then by_key[tag]=group end end
  group[#group+1]=i
 end
 return groups
end
-- Remove the unused column between compatible banks, retaining separate feed belts.
function M.pack(entities,blocks,limit)
 local packed=0
 local function shift(b,dx)
  if dx==0 then return end
  for i=b.entity_first,b.entity_last do entities[i].position.x=entities[i].position.x+dx end
  local seen={}
  local function move(t)
   if seen[t] then return end;seen[t]=true
   for k,v in pairs(t) do
    if type(v)=='table' and k~='recipe_node' then move(v)
    elseif type(v)=='number' and (k=='x' or k=='offset_x') then t[k]=v+dx end
   end
  end
  move(b)
 end
 for _,group in ipairs(groups_for(blocks,limit)) do if #group>1 then
  local eligible=true;for _,bi in ipairs(group) do if blocks[bi].protected_bounds then eligible=false end end
  if eligible then
   local moves={};local right
   for _,bi in ipairs(group) do local b=blocks[bi];local left,last=math.huge,-math.huge
    for i=b.entity_first,b.entity_last do local e=entities[i];local p=prototypes.entity[e.name];local w=p.tile_width
     if (e.direction or 0)%8==4 then w=p.tile_height end
     left=math.min(left,math.floor(e.position.x-w/2+.001));last=math.max(last,math.ceil(e.position.x+w/2-.001))
    end
    local dx=right and math.min(0,right-left) or 0;shift(b,dx);moves[#moves+1]={block=b,dx=dx};right=last+dx
   end
   local es,bs={},{}
   for _,bi in ipairs(group) do local b=blocks[bi];local first=#es+1
    for i=b.entity_first,b.entity_last do es[#es+1]=entities[i] end
    bs[#bs+1]={entity_first=first,entity_last=#es,inputs={}}
   end
   if #contacts.between(es,bs)>0 then for _,m in ipairs(moves) do shift(m.block,-m.dx) end
   else for _,m in ipairs(moves) do if m.dx<0 then packed=packed+1 end end end
  end
 end end
 return packed
end
-- One raw-fuel inlet serves the adjacent sections through a surface splitter chain.
function M.prepare(entities,blocks,settings,en,catalog,limit,packing)
 local produced={};for _,b in ipairs(blocks) do for _,p in ipairs((b.recipe_node or {}).products or {}) do produced[p.name]=true end end
 local splitter
 for _,name in ipairs(catalog.splitters or {}) do local p=prototypes.entity[name]
  if p.belt_speed>=prototypes.entity[settings.belt_in].belt_speed and (not splitter or p.belt_speed<prototypes.entity[splitter].belt_speed) then splitter=name end
 end
 if not splitter then return en,0,0 end
 local packed=packing and M.pack(entities,blocks,limit) or 0
 local occupied={}
 for _,e in ipairs(entities) do local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if (e.direction or 0)%8==4 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  for xx=x,x+w-1 do for yy=y,y+h-1 do occupied[xx..','..yy]=true end end
 end
 local extras={};local shared=0;local collected_count=0
 for _,indices in ipairs(groups_for(blocks,limit)) do if #indices>1 then
  for _,bi in ipairs(indices) do blocks[bi].routing_group=indices[1] end
  local first=blocks[indices[1]];local fuel
  -- Keep all independent capacity-sized product belts on one array edge.
  local bottom=-math.huge;local align=true
  for _,bi in ipairs(indices) do local b=blocks[bi];local p=b.product_out
   if not p or (p.direction or 8)~=8 or b.product_outs or b.output_ports then align=false;break end
   bottom=math.max(bottom,p.y)
  end
  if align then
   for _,bi in ipairs(indices) do local p=blocks[bi].product_out;for y=p.y,bottom do if y>p.y and occupied[p.x..','..y] then align=false end end end
   if align then for _,bi in ipairs(indices) do local b=blocks[bi];local p=b.product_out
    local list=extras[bi] or {};extras[bi]=list
    for y=p.y,bottom do if p.y<bottom and not occupied[p.x..','..y] then list[#list+1]={entity_number=en,name=settings.belt_out,position={x=p.x+.5,y=y+.5},direction=8};en=en+1;occupied[p.x..','..y]=true end end
    p.y=bottom;b.height=math.max(b.height or 0,bottom-(b.offset_y or 0)+1)
   end end
  end
  local machine=prototypes.entity[first.recipe_node.factory.name]
  if machine and machine.burner_prototype then for _,p in ipairs(first.recipe_node.ingredients or {}) do local item=prototypes.item[resources.name(p.name)]
   if p.type~='fluid' and item and item.fuel_value and item.fuel_value>0 and not produced[p.name] then fuel=p.name;break end
  end end
  if fuel then
   local ports,total={},0;local valid=true
   for _,bi in ipairs(indices) do local b=blocks[bi];local found
    for _,p in ipairs(b.inputs or {}) do if p.ingredient==fuel then found=p;break end end
    local rate=0;for _,v in ipairs(b.recipe_node.ingredients or {}) do if v.name==fuel then rate=rate+capacity.flow(v,b.recipe_node) end end
    if not found or rate<=0 or (ports[1] and found.y~=ports[1].p.y) then valid=false;break end
    ports[#ports+1]={p=found,rate=rate};total=total+rate
   end
   if valid then
    local y=ports[1].p.y-3;local start=ports[1].p.x-3;local finish=ports[#ports].p.x
    for x=start,finish do if occupied[x..','..y] then valid=false end end
    for k,v in ipairs(ports) do
     if k<#ports and occupied[(v.p.x-1)..','..(y+1)] then valid=false end
     for yy=y+1,y+2 do if occupied[v.p.x..','..yy] then valid=false end end
    end
   end
   if valid and total<=capacity.belt(settings.belt_in)+1e-8 then
    local owner=indices[1];local list=extras[owner] or {};extras[owner]=list
    local function add(name,x,y,d,w,h)
     list[#list+1]={entity_number=en,name=name,position={x=x+(w or 1)/2,y=y+(h or 1)/2},direction=d};en=en+1
     for xx=x,x+(w or 1)-1 do for yy=y,y+(h or 1)-1 do occupied[xx..','..yy]=true end end
    end
    local y=ports[1].p.y-3;local start=ports[1].p.x-3;local finish=ports[#ports].p.x
    local splits={};for k=1,#ports-1 do splits[ports[k].p.x-1]=true end
    for x=start,finish do
     if splits[x] then add(splitter,x,y,4,1,2)
     else add(settings.belt_in,x,y,x==finish and 8 or 4) end
    end
    for k,v in ipairs(ports) do
     add(settings.belt_in,v.p.x,y+1,8);add(settings.belt_in,v.p.x,y+2,8)
     v.p.array_local=true;v.p.array_source_owner=owner;v.p.planned_rate=v.rate;v.p.connected_rate=v.rate
    end
    first.inputs[#first.inputs+1]={x=start,y=y,direction=4,ingredient=fuel,array_supply_rate=total}
    shared=shared+1
   end
  end
  local collected;en,collected=array_outputs.prepare(entities,blocks,indices,extras,occupied,settings,en,catalog)
  if collected then collected_count=collected_count+1 end
 end end
 if next(extras) then
  local out={}
  for bi,b in ipairs(blocks) do local a,z=b.entity_first,b.entity_last;b.entity_first=#out+1
   for i=a,z do out[#out+1]=entities[i] end
   for _,e in ipairs(extras[bi] or {}) do out[#out+1]=e end
   b.entity_last=#out
  end
  for i=#entities,1,-1 do entities[i]=nil end;for i,e in ipairs(out) do entities[i]=e end
 end
 return en,shared,packed,collected_count
end
function M.available(blocks)
 for _,group in ipairs(groups_for(blocks)) do if #group>1 then return true end end
 return false
end
function M.place(blocks,planner,options)
 local groups=groups_for(blocks,options.limit)
 local coarse={}
 for gi,indices in ipairs(groups) do
  if #indices==1 then coarse[gi]=blocks[indices[1]] else
   local q={layout_belt_capacity=blocks[indices[1]].layout_belt_capacity,layout_output_ports={},spatial_group=blocks[indices[1]].spatial_group,layout_left=math.huge,layout_top=math.huge,layout_belt_guards={},layout_fluid_ports={},inputs={},layout_input_dirs={},products={},recipe_node={base_time=1,ingredients={},products={}}}
   local right,bottom=-math.huge,-math.huge;local ins,outs={},{}
   for _,i in ipairs(indices) do local b=blocks[i]
    q.layout_left=math.min(q.layout_left,b.layout_left);q.layout_top=math.min(q.layout_top,b.layout_top)
    right=math.max(right,b.layout_left+b.layout_width);bottom=math.max(bottom,b.layout_top+b.layout_height)
    for _,p in ipairs(b.layout_belt_guards or {}) do q.layout_belt_guards[#q.layout_belt_guards+1]=p end
    for _,side in ipairs({'ingredients','products'}) do local target=side=='ingredients' and ins or outs
     for _,p in ipairs((b.recipe_node or {})[side] or {}) do target[p.name]=(target[p.name] or 0)+capacity.flow(p,b.recipe_node) end
    end
   end
   q.layout_width=right-q.layout_left;q.layout_height=bottom-q.layout_top
   local names={};for name in pairs(ins) do names[#names+1]=name end;table.sort(names)
   for _,name in ipairs(names) do q.recipe_node.ingredients[#q.recipe_node.ingredients+1]={name=name,count=ins[name]} end
   for _,i in ipairs(indices) do local b=blocks[i]
    for pi,p in ipairs(b.inputs or {}) do if not p.array_local then
     local rate=p.graph_rate or p.array_supply_rate
     if not rate then for _,v in ipairs(b.recipe_node.ingredients or {}) do if v.name==p.ingredient then rate=capacity.flow(v,b.recipe_node);break end end end
     q.inputs[#q.inputs+1]={x=p.x,y=p.y,ingredient=p.ingredient,flow_edge=p.flow_edge,graph_rate=p.graph_rate,layout_rate=rate}
     q.layout_input_dirs[#q.inputs]=(b.layout_input_dirs or {})[pi] or p.direction or 8
    end end
   end
   names={};for name in pairs(outs) do names[#names+1]=name end;table.sort(names)
   for _,name in ipairs(names) do q.products[#q.products+1]=name;q.recipe_node.products[#q.recipe_node.products+1]={name=name,count=outs[name]} end
   q.product_out={x=q.layout_left+math.floor(q.layout_width/2),y=bottom-1};q.layout_output_dir=8
   local wx,wy,weight=0,0,0
   for _,i in ipairs(indices) do local b=blocks[i]
    local ports=b.output_ports or (b.product_out and {b.product_out}) or {}
    for _,p in ipairs(ports) do for _,v in ipairs(b.recipe_node.products or {}) do q.layout_output_ports[#q.layout_output_ports+1]={x=p.x,y=p.y,direction=p.direction or b.layout_output_dir or 8,product=v.name,flow_edge=p.flow_edge,graph_terminal=p.graph_terminal,terminal_slot=p.terminal_slot,rate=capacity.flow(v,b.recipe_node)*(p.share or 1)} end end
    if b.output_ports then for _,p in ipairs(b.output_ports) do local rate=0
     for _,v in ipairs(b.recipe_node.products or {}) do rate=rate+capacity.flow(v,b.recipe_node)*(p.share or 1) end
     wx=wx+p.x*rate;wy=wy+p.y*rate;weight=weight+rate
    end end
   end
   if weight>0 then q.product_out={x=math.floor(wx/weight+.5),y=math.floor(wy/weight+.5)} end
   q.layout_terminal_only=#q.layout_output_ports>0
   for _,p in ipairs(q.layout_output_ports) do if not p.graph_terminal then q.layout_terminal_only=false end end
   coarse[gi]=q
  end
 end
 -- Pack upstream groups before their consumers; Helmod's flattened order
 -- can otherwise place the large furnace groups after the assemblers.
 local producers,edges,degree={},{},{}
 for i,b in ipairs(coarse) do edges[i]={};degree[i]=0;for _,p in ipairs((b.recipe_node or {}).products or {}) do
  if capacity.flow(p,b.recipe_node)>1e-8 then producers[p.name]=producers[p.name] or {};producers[p.name][#producers[p.name]+1]=i end
 end end
 for i,b in ipairs(coarse) do for _,p in ipairs((b.recipe_node or {}).ingredients or {}) do
  if capacity.flow(p,b.recipe_node)>1e-8 then for _,j in ipairs(producers[p.name] or {}) do if i~=j and not edges[j][i] then edges[j][i]=true;degree[i]=degree[i]+1 end end end
 end end
 local order,seen={},{};for i=1,#coarse do if degree[i]==0 then order[#order+1]=i;seen[i]=true end end
 local head=1;while order[head] do local i=order[head];head=head+1
  for j=1,#coarse do if edges[i][j] then degree[j]=degree[j]-1;if degree[j]==0 and not seen[j] then order[#order+1]=j;seen[j]=true end end end
 end
 for i=1,#coarse do if not seen[i] then order[#order+1]=i end end
 local ordered={};for k,i in ipairs(order) do ordered[k]=coarse[i] end
 local placements,clusters
 if options.hierarchical then placements,clusters=hierarchy.place(ordered,planner,options) elseif options.method=='compact' then placements=planner.compact(ordered,options.gap,options.compact,true,options.ratio) else placements=planner.dense(ordered,options.gap,options.compact,options.align_ports,options.ratio,options.thorough,options.boundary,true) end
 local mapped,mapped_clusters={},{};for k,i in ipairs(order) do mapped[i]=placements[k];mapped_clusters[i]=clusters and clusters[k] end;placements=mapped
 local result={}
 for gi,indices in ipairs(groups) do local q,d=coarse[gi],placements[gi];local turn=d.turn or 0
  for _,i in ipairs(indices) do local b=blocks[i];b.routing_cluster=mapped_clusters[gi];local left,top=math.huge,math.huge
   for _,p in ipairs({{b.layout_left,b.layout_top},{b.layout_left+b.layout_width,b.layout_top},{b.layout_left,b.layout_top+b.layout_height},{b.layout_left+b.layout_width,b.layout_top+b.layout_height}}) do
    local x,y=p[1]-q.layout_left,p[2]-q.layout_top;local w,h=q.layout_width,q.layout_height
    for t=1,turn do x,y=h-y,x;w,h=h,w end
    left=math.min(left,q.layout_left+x);top=math.min(top,q.layout_top+y)
   end
   result[i]={x=left+d.x-b.layout_left,y=top+d.y-b.layout_top,turn=turn}
  end
 end
 return result
end
return M
