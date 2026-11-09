-- Build small dependency compounds before arranging the whole production graph.
local M={}
local capacity=require('capacity')
local work=require('generation_work')
local function rates(b,side)
 local r={};for _,p in ipairs((b.recipe_node or {})[side] or {}) do r[p.name]=(r[p.name] or 0)+capacity.flow(p,b.recipe_node) end;return r
end
local function point(p,d,w,h,turn)
 local x,y=p.x+.5,p.y+.5
 for _=1,turn do x,y=h-y,x;w,h=h,w end
 local q=work.copy(p);q.x,q.y=x-.5+d.x,y-.5+d.y
 if q.direction then q.direction=(q.direction+turn*4)%16 end
 return q
end
local function compose(leaf,d,w,h,turn)
 local left,top=math.huge,math.huge
 for _,p in ipairs({{leaf.x,leaf.y},{leaf.x+leaf.w,leaf.y},{leaf.x,leaf.y+leaf.h},{leaf.x+leaf.w,leaf.y+leaf.h}}) do
  local x,y=p[1],p[2];local ww,hh=w,h
  for _=1,turn do x,y=hh-y,x;ww,hh=hh,ww end
  left=math.min(left,x);top=math.min(top,y)
 end
 return {index=leaf.index,x=left+d.x,y=top+d.y,w=turn%2==0 and leaf.w or leaf.h,h=turn%2==0 and leaf.h or leaf.w,turn=(leaf.turn+turn)%4}
end
local function aggregate(children,placements)
 local g={layout_belt_capacity=children[1].geometry.layout_belt_capacity,layout_left=0,layout_top=0,layout_width=0,layout_height=0,layout_belt_guards={},layout_fluid_ports={},inputs={},layout_input_dirs={},products={},recipe_node={base_time=1,ingredients={},products={}}}
 local ins,outs={},{};local candidates,output_points={},{};local leaves={};local families={}
 for _,node in ipairs(children) do for name in pairs(node.families or {}) do families[name]=true end end
 for i,node in ipairs(children) do local b,d=node.geometry,placements[i];local turn=d.turn or 0;local w,h=b.layout_width,b.layout_height
  g.layout_width=math.max(g.layout_width,d.x+(turn%2==0 and w or h));g.layout_height=math.max(g.layout_height,d.y+(turn%2==0 and h or w))
  for _,side in ipairs({'ingredients','products'}) do local dst=side=='ingredients' and ins or outs
   for name,rate in pairs(rates(b,side)) do dst[name]=(dst[name] or 0)+rate end
  end
  for ii,p in ipairs(b.inputs or {}) do local q=point(p,d,w,h,turn);q.direction=(((b.layout_input_dirs or {})[ii] or p.direction or 8)+turn*4)%16;candidates[#candidates+1]=q end
  if b.layout_output_ports then
   for _,p in ipairs(b.layout_output_ports) do local q=point(p,d,w,h,turn);q.direction=((p.direction or b.layout_output_dir or 8)+turn*4)%16;output_points[#output_points+1]=q end
  elseif b.product_out then
   for name,rate in pairs(rates(b,'products')) do local q=point(b.product_out,d,w,h,turn);q.direction=((b.layout_output_dir or 8)+turn*4)%16;q.product=name;q.rate=rate;output_points[#output_points+1]=q end
  end
  for _,p in ipairs(b.layout_belt_guards or {}) do g.layout_belt_guards[#g.layout_belt_guards+1]=point(p,d,w,h,turn) end
  for _,p in ipairs(b.layout_fluid_ports or {}) do g.layout_fluid_ports[#g.layout_fluid_ports+1]=point(p,d,w,h,turn) end
  for _,leaf in ipairs(node.leaves) do leaves[#leaves+1]=compose(leaf,d,w,h,turn) end
 end
 local bound,arrivals,departures={},{},{}
 for _,p in ipairs(candidates) do if p.flow_edge then bound[p.ingredient]=true;arrivals[p.flow_edge]=true end end
 for _,p in ipairs(output_points) do if p.flow_edge or p.graph_terminal then bound[p.product]=true end;if p.flow_edge then departures[p.flow_edge]=true end end
 local names={};for n in pairs(ins) do names[#names+1]=n end;for n in pairs(outs) do if not ins[n] then names[#names+1]=n end end;table.sort(names)
 for _,name in ipairs(names) do
  if bound[name] then
   local incoming,outgoing=0,0
   for _,p in ipairs(candidates) do if p.ingredient==name and not (p.flow_edge and departures[p.flow_edge]) then
    local rate=p.graph_rate or p.layout_rate or 0;incoming=incoming+rate;p.layout_rate=rate;g.inputs[#g.inputs+1]=p;g.layout_input_dirs[#g.inputs]=p.direction
   end end
   for _,p in ipairs(output_points) do if p.product==name and not (p.flow_edge and arrivals[p.flow_edge]) then outgoing=outgoing+(p.rate or 0) end end
   if incoming>1e-8 then g.recipe_node.ingredients[#g.recipe_node.ingredients+1]={name=name,count=incoming} end
   if outgoing>1e-8 then g.products[#g.products+1]=name;g.recipe_node.products[#g.recipe_node.products+1]={name=name,count=outgoing} end
  else
   local net=(outs[name] or 0)-(ins[name] or 0)
   if net>1e-8 then g.products[#g.products+1]=name;g.recipe_node.products[#g.recipe_node.products+1]={name=name,count=net}
   elseif net< -1e-8 then
    g.recipe_node.ingredients[#g.recipe_node.ingredients+1]={name=name,count=-net}
    local count=0;for _,p in ipairs(candidates) do if p.ingredient==name then count=count+1 end end
    for _,p in ipairs(candidates) do if p.ingredient==name then g.inputs[#g.inputs+1]=p;g.layout_input_dirs[#g.inputs]=p.direction;p.layout_rate=-net/count end end
   end
  end
 end
 local sumx,sumy,weight=0,0,0;g.layout_output_ports={}
 for _,p in ipairs(output_points) do
  local keep=bound[p.product] and not (p.flow_edge and arrivals[p.flow_edge]) or not bound[p.product] and (outs[p.product] or 0)>(ins[p.product] or 0)+1e-8
  if keep then
   local rate=p.rate or 1
   if not bound[p.product] then p.rate=rate*((outs[p.product] or 0)-(ins[p.product] or 0))/(outs[p.product] or 1) end
   g.layout_output_ports[#g.layout_output_ports+1]=p;sumx=sumx+p.x*rate;sumy=sumy+p.y*rate;weight=weight+rate
  end
 end
 if weight>0 then g.product_out={x=math.floor(sumx/weight+.5),y=math.floor(sumy/weight+.5)};g.layout_output_dir=g.layout_output_ports[1].direction end
 g.layout_terminal_only=#g.layout_output_ports>0
 for _,p in ipairs(g.layout_output_ports) do if not p.graph_terminal then g.layout_terminal_only=false end end
 return {geometry=g,leaves=leaves,families=families}
end
function M.place(blocks,planner,options)
 return work.cached('dependency-hierarchy',function()
  local nodes=work.cached('hierarchy-leaves',function()
  local nodes={}
  for i,b in ipairs(blocks) do local q=work.copy(b);local dx,dy=-b.layout_left,-b.layout_top
   q.layout_left,q.layout_top=0,0
   local function shift(p)p.x=p.x+dx;p.y=p.y+dy end
   if q.product_out then shift(q.product_out) end
   for _,field in ipairs({'inputs','layout_belt_guards','layout_fluid_ports','layout_output_ports'}) do for _,p in ipairs(q[field] or {}) do shift(p) end end
   nodes[i]={geometry=q,families={[q.spatial_group or ('node'..i)]=true},leaves={{index=i,x=0,y=0,w=q.layout_width,h=q.layout_height,turn=0}}}
   if q.spatial_group and q.product_out then
    local turn=((8-(q.layout_output_dir or 8))%16)/4
    if turn~=0 then nodes[i]=aggregate({nodes[i]},{{x=0,y=0,turn=turn}}) end
   end
  end
  return nodes
  end,true)
  while true do
   local following=work.cached('hierarchy-merge',function()
   local best;local producers,consumers={},{}
   for i,n in ipairs(nodes) do for name,rate in pairs(rates(n.geometry,'products')) do producers[name]=producers[name] or {};producers[name][i]=rate end
    for name,rate in pairs(rates(n.geometry,'ingredients')) do consumers[name]=consumers[name] or {};consumers[name][i]=rate end
   end
   local function family_count(a,b)
    local seen={};for name in pairs(nodes[a].families) do seen[name]=true end;for name in pairs(nodes[b].families) do seen[name]=true end
    local n=0;for _ in pairs(seen) do n=n+1 end;return n
   end
   for a=1,#nodes-1 do for b=a+1,#nodes do if family_count(a,b)==1 then
    if not best or best.score<.4 or (a<best.a or (a==best.a and b<best.b)) then best={a=a,b=b,score=.4,family=true} end
   end end end
   local bound,edge_sources,outgoing,incoming,pairs_by_item={},{},{},{},{}
   for i,node in ipairs(nodes) do for _,p in ipairs(node.geometry.layout_output_ports or {}) do
    if p.flow_edge then
     bound[p.product]=true;edge_sources[p.flow_edge]={node=i,item=p.product,rate=p.rate or 0}
     outgoing[i]=outgoing[i] or {};outgoing[i][p.product]=(outgoing[i][p.product] or 0)+(p.rate or 0)
    elseif p.graph_terminal then bound[p.product]=true end
   end end
   for j,node in ipairs(nodes) do for _,p in ipairs(node.geometry.inputs or {}) do if p.flow_edge then
    bound[p.ingredient]=true;incoming[j]=incoming[j] or {};local rate=p.graph_rate or p.layout_rate or 0;incoming[j][p.ingredient]=(incoming[j][p.ingredient] or 0)+rate
    local source=edge_sources[p.flow_edge]
    if source and source.node~=j then
     local map=pairs_by_item[p.ingredient] or {};pairs_by_item[p.ingredient]=map;map[source.node]=map[source.node] or {};map[source.node][j]=(map[source.node][j] or 0)+rate
    end
   end end end
   for name,sources in pairs(pairs_by_item) do for a,targets in pairs(sources) do for b,rate in pairs(targets) do
    if family_count(a,b)<=(options.cluster_limit or 4) then
     local strength=rate/math.max((outgoing[a] or {})[name] or rate,(incoming[b] or {})[name] or rate)
     if not best or strength>best.score or (strength==best.score and (a<best.a or (a==best.a and b<best.b))) then best={a=a,b=b,score=strength} end
    end
   end end end
   for name,sources in pairs(producers) do local sinks=consumers[name] or {};local fanout=0;for _ in pairs(sinks) do fanout=fanout+1 end
    for a,available in pairs(sources) do for b,need in pairs(sinks) do
     if not bound[name] and a~=b and family_count(a,b)<=(options.cluster_limit or 4) and (fanout<=2 or need>=available*.8) then
      local strength=math.min(available,need)/math.max(available,need)/math.max(1,fanout)
      if strength>=.2 and (not best or strength>best.score or (strength==best.score and (a<best.a or (a==best.a and b<best.b)))) then best={a=a,b=b,score=strength} end
     end
    end end
   end
   if not best then return nil end
   local children={nodes[best.a],nodes[best.b]};local gs={children[1].geometry,children[2].geometry}
   local placements
   if best.family then
    local materials={}
    local function side_inputs(g,direction)
      for i,d in ipairs(g.layout_input_dirs or {}) do if d==direction then materials[g.inputs[i].ingredient]=true end end
    end
    side_inputs(gs[1],12);side_inputs(gs[2],4)
    local gap=0;for _ in pairs(materials) do gap=gap+1 end
    local exits=0
    for _,p in ipairs(gs[1].layout_output_ports or {}) do if p.direction==4 then exits=exits+1 end end
    for _,p in ipairs(gs[2].layout_output_ports or {}) do if p.direction==12 then exits=exits+1 end end
    gap=math.max(gap,exits+(exits>1 and 1 or 0))
    local bottom=math.max(gs[1].layout_height,gs[2].layout_height)
    placements={{x=0,y=bottom-gs[1].layout_height,turn=0},{x=gs[1].layout_width+gap,y=bottom-gs[2].layout_height,turn=0}}
   else
    placements=planner.dense(gs,0,1,false,nil,options.thorough,options.boundary and {side=options.boundary,terminal_only=true} or nil,true,options.approach or 1)
   end
   local combined=aggregate(children,placements);local next_nodes={}
   for i,node in ipairs(nodes) do if i~=best.a and i~=best.b then next_nodes[#next_nodes+1]=node end end
   next_nodes[#next_nodes+1]=combined
   return next_nodes
   end,true)
   if not following then break end
   nodes=following
   work.section_boundary()
  end
  local gs={};for i,n in ipairs(nodes) do gs[i]=n.geometry end
  local global=planner.dense(gs,0,options.compact,false,options.ratio,options.thorough,options.boundary,true,options.approach or 1)
  local result,clusters={},{}
  for ci,node in ipairs(nodes) do local d=global[ci];local b=node.geometry
   for _,leaf in ipairs(node.leaves) do local q=compose(leaf,d,b.layout_width,b.layout_height,d.turn or 0);local original=blocks[q.index]
    result[q.index]={x=q.x-original.layout_left,y=q.y-original.layout_top,turn=q.turn};clusters[q.index]=ci
   end
  end
  return result,clusters
 end)
end
return M
