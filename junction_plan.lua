-- Allocate flows and build their junctions before arranging production blocks.
local M={}
local work=require('generation_work')
local capacity=require('capacity')
local priorities=require('flow_priorities')
local lane_balance=require('lane_balance')
local containers=require('container_distribution')
local vec={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
local function occupy(es,b)
 local cells={}
 for i=b.entity_first,b.entity_last do local e=es[i];local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if (e.direction or 0)%8==4 then w,h=h,w end
  local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001)
  for xx=x,x+w-1 do for yy=y,y+h-1 do cells[key(xx,yy)]=true end end
 end
 for _,p in ipairs(b.inputs or {}) do cells[key(p.x,p.y)]=true end
 for _,p in ipairs(b.output_ports or (b.product_out and {b.product_out}) or {}) do cells[key(p.x,p.y)]=true end
 for _,p in ipairs(b.junction_guards or {}) do cells[key(p.x,p.y)]=true end
 return cells
end
local function emit(root,n,reverse,belt,split,cells,id,links)
 if n==1 then return {},{},{{x=root.x,y=root.y,direction=root.direction or 8}},id end
 local function transform(x,y,d,mirror,turn)
  if mirror then x=1-x;d=(16-d)%16 end
  for _=1,turn do x,y=1-y,x;d=(d+4)%16 end
  return root.x+x,root.y+y,d
 end
 local direction=root.direction or 8;local turn=((direction-(reverse and 0 or 8))%16)/4
 for lead=0,12,2 do for _,mirror in ipairs({false,true}) do
  local es,guards,ports={}, {},{};local occupied={};local valid=true
  local function point(x,y,d)
   local xx,yy,dd=transform(x+.5,y+.5,reverse and (d+8)%16 or d,mirror,turn)
   return {x=xx-.5,y=yy-.5,direction=dd}
  end
  local function add(name,x,y,d,w,h,priority,merging)
   local xx,yy,dd=transform(x+w/2,y+h/2,reverse and (d+8)%16 or d,mirror,turn)
   local ww,hh=w,h;if turn%2==1 then ww,hh=hh,ww end
   local left,top=math.floor(xx-ww/2+.001),math.floor(yy-hh/2+.001)
   for a=left,left+ww-1 do for b=top,top+hh-1 do local k=key(a,b);if cells[k] or occupied[k] then valid=false end;occupied[k]=true end end
   local e={entity_number=id+#es,name=name,position={x=xx,y=yy},direction=dd}
   local sx,sy=mirror and -1 or 1,0;for _=1,turn do sx,sy=-sy,sx end
   if priority then e.output_priority=priorities.half(dd,sx,sy,priority=='branch') end
   if merging then e.input_priority=priorities.half(dd,sx,sy,true) end
   es[#es+1]=e
  end
  for y=1,lead do add(belt,0,y,8,1,1) end
  for i=1,n-1 do local y=lead+3*(i-1)+1
   local priority=not reverse and 'branch' or nil
   local merging=reverse and links and {ordered=true} or nil
   add(split,0,y,8,2,1,priority,merging)
   add(belt,1,y+1,reverse and 8 or 4,1,1);add(belt,2,y+1,4,1,1)
   ports[i]=point(2,y+1,4)
   add(belt,0,y+1,8,1,1)
   if i<n-1 then add(belt,0,y+2,8,1,1) else ports[n]=point(0,y+1,8) end
   local g=point(1,y-1,8);guards[#guards+1]=g
  end
  for _,g in ipairs(guards) do local k=key(g.x,g.y);if cells[k] or occupied[k] then valid=false end end
  if valid then return es,guards,ports,id+#es end
 end end
end
-- Pool every producer of a material in one inventory, so allocations cannot
-- strand stock in an earlier producer/consumer pair.
local function pool(es,bs,name,sources,sinks,rate,settings,id,sequence)
 local need=0;for _,t in ipairs(sinks) do need=need+t.rate end
 if #sinks==0 or rate<=1e-8 or need>rate+1e-8 then return id,sequence,false end
 local context=work.copy(settings.container_context);context.internal=true
 if not containers.select(context,#sources,#sinks) then
  context.output_collector=true
  if not containers.select(context,#sources,#sinks) then error({'bfh.container-no-size',#sources,#sinks},0) end
 end
 local box=containers.select(context,#sources,#sinks)
 local y=0;for _,b in ipairs(bs) do y=math.max(y,(b.offset_y or 0)+(b.height or 0)+8) end
 local extra,outputs,inputs={},{},{}
 for _,s in ipairs(sources) do
  local b=bs[s.bi];local present=false
  for i=b.entity_first,b.entity_last do local e=es[i]
   if math.floor(e.position.x)==s.port.x and math.floor(e.position.y)==s.port.y then present=true;break end
  end
  if not present then
   extra[s.bi]=extra[s.bi] or {};extra[s.bi][#extra[s.bi]+1]={entity_number=id,name=settings.belt_out,
    position={x=s.port.x+.5,y=s.port.y+.5},direction=s.port.direction or 8};id=id+1
  end
 end
 local hub={};local ins,outs,height,nextid=containers.emit(hub,id,context,{belt_in=settings.belt_out},
  #sources,#sinks,box.w+5,y,name);id=nextid
 for i,s in ipairs(sources) do
  sequence=sequence+1;local q=work.copy(s.port)
  q.flow_edge=sequence;q.graph_terminal=false;q.terminal_slot=nil
  q.share=s.rate/capacity.flow(bs[s.bi].recipe_node.products[1],bs[s.bi].recipe_node)
  outputs[s.bi]=outputs[s.bi] or {};outputs[s.bi][#outputs[s.bi]+1]=q
  ins[i].ingredient=name;ins[i].flow_edge=sequence;ins[i].graph_rate=s.rate;ins[i].layout_rate=s.rate
 end
 for i,t in ipairs(sinks) do
  sequence=sequence+1;local p=outs[i]
  p.share=t.rate/rate;p.buffered_distribution=#sinks>1
  p.graph_terminal=not not t.terminal;p.terminal_slot=t.slot
  if not t.terminal then
   p.flow_edge=sequence;local q=work.copy(t.port)
   q.flow_edge=sequence;q.graph_rate=t.rate;q.layout_rate=t.rate
   inputs[t.bi]=inputs[t.bi] or {};inputs[t.bi][t.port]=q
  end
 end
 local result={}
 for bi,b in ipairs(bs) do
  local first=#result+1
  for i=b.entity_first,b.entity_last do result[#result+1]=es[i] end
  for _,e in ipairs(extra[bi] or {}) do result[#result+1]=e end
  b.entity_first,b.entity_last=first,#result
  if outputs[bi] then b.output_ports=outputs[bi];b.product_out=work.copy(outputs[bi][1]);b.graph_bound=true end
  if inputs[bi] then for i,p in ipairs(b.inputs) do b.inputs[i]=inputs[bi][p] or p end;b.graph_bound=true end
 end
 local first=#result+1;for _,e in ipairs(hub) do result[#result+1]=e end
 bs[#bs+1]={offset_x=0,offset_y=y,width=box.w+5,height=height,entity_first=first,entity_last=#result,
  inputs=ins,output_ports=outs,product_out=work.copy(outs[1]),products={name},machine_ids={},graph_bound=true,pool_container=true,
  recipe_node={name='__bfh_pool__'..name,base_time=1,factory={name=box.name,count=1},
   ingredients={{name=name,type='item',count=rate}},products={{name=name,type='item',count=rate}}}}
 for i=#es,1,-1 do es[i]=nil end;for i,e in ipairs(result) do es[i]=e end
 return id,sequence,true
end
local function resource(es,bs,name,exports,settings,id,sequence)
 local sources,sinks={},{};local rate=0
 local function direction(p,b)
  if p.direction then return end
  for i=b.entity_first,b.entity_last do local e=es[i];if math.floor(e.position.x)==p.x and math.floor(e.position.y)==p.y then
   local kind=prototypes.entity[e.name].type;if kind=='transport-belt' or kind=='underground-belt' then p.direction=e.direction or 0;return end
  end end
  p.direction=8
 end
 for bi,b in ipairs(bs) do
  if #(b.recipe_node.products or {})==1 and not b.product_outs then
   local product=b.recipe_node.products[1]
   if product.name==name and product.type~='fluid' then
    for _,p in ipairs(b.output_ports or (b.product_out and {b.product_out}) or {}) do
     direction(p,b)
     local amount=capacity.flow(product,b.recipe_node)*(p.share or 1)
     local count=((b.recipe_node or {}).factory or {}).count or 1
     local asymmetric=not b.balanced_output and (b.single_bank or b.is_single_assembler_block or count%2==1)
     sources[#sources+1]={bi=bi,port=p,remaining=amount,rate=amount,links={},asymmetric=asymmetric,pooled=b.output_ports and #b.output_ports>1};rate=rate+amount
    end
   end
  elseif b.products then for _,n in ipairs(b.products) do if n==name then return id,sequence,false end end end
  for _,p in ipairs(b.inputs or {}) do if p.ingredient==name and not p.array_local then
   direction(p,b)
   local amount=p.graph_rate or p.array_supply_rate
   if not amount then for _,v in ipairs(b.recipe_node.ingredients or {}) do if v.name==name then amount=capacity.flow(v,b.recipe_node) end end end
   if amount and amount>1e-8 then sinks[#sinks+1]={bi=bi,port=p,rate=amount,links={}} end
  end end
 end
 if #sources==0 then return id,sequence,false end
 for _,s in ipairs(sources) do for _,t in ipairs(sinks) do if s.bi==t.bi then return id,sequence,false end end end
 local total_export=exports[name] or 0;local count=math.ceil(total_export/settings.export_capacity-1e-9)
 for i=1,count do sinks[#sinks+1]={terminal=true,slot=i,rate=total_export/count,links={}} end
 if settings.container_context and (#sources>1 or #sinks>1) then return pool(es,bs,name,sources,sinks,rate,settings,id,sequence) end
 table.sort(sinks,function(a,b)if a.terminal~=b.terminal then return not not a.terminal end;if a.rate~=b.rate then return a.rate>b.rate end;return (a.bi or a.slot)<(b.bi or b.slot) end)
 for _,t in ipairs(sinks) do local remaining=t.rate
  while remaining>1e-8 do local best,score
   for _,s in ipairs(sources) do if s.remaining>1e-8 then
    local distance=t.port and (math.abs(s.port.x-t.port.x)+math.abs(s.port.y-t.port.y)) or 0
    local value=(math.abs(s.remaining-remaining)<1e-8 and 0 or s.remaining>=remaining and 100000 or 200000)+distance
    if not score or value<score then best,score=s,value end
   end end
   if not best then return id,sequence,false end
   local amount=math.min(remaining,best.remaining);sequence=sequence+1
   local link={id=sequence,rate=amount,source=best,target=t,terminal=t.terminal,slot=t.slot}
   best.links[#best.links+1]=link;t.links[#t.links+1]=link;best.remaining=best.remaining-amount;remaining=remaining-amount
  end
 end
 if not priorities.tree(sources,sinks) then return id,sequence,false end
 local extras,guards,occupied,outputs,inputs={},{},{},{},{}
 for bi,b in ipairs(bs) do occupied[bi]=occupy(es,b);extras[bi]={};guards[bi]={} end
 local start=id
 local function build(owner,root,links,reverse)
  -- Older templates expose a virtual outlet one cell beyond their last belt.
  -- A prebuilt tree must materialize that bridge before moving the public port.
  local present=false
  for i=bs[owner].entity_first,bs[owner].entity_last do local e=es[i];local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
   if (e.direction or 0)%8==4 then w,h=h,w end
   if root.x+.5>=e.position.x-w/2 and root.x+.5<e.position.x+w/2 and root.y+.5>=e.position.y-h/2 and root.y+.5<e.position.y+h/2 then
    if p.type~='transport-belt' and p.type~='underground-belt' then return end
    present=true;break
   end
  end
  if not present then
   extras[owner][#extras[owner]+1]={entity_number=id,name=settings.belt_out,position={x=root.x+.5,y=root.y+.5},direction=root.direction or 8};id=id+1
  end
  local more,empty,ports,nextid
  more,empty,ports,nextid=emit(root,#links,reverse,settings.belt_out,settings.splitter,occupied[owner],id,links)
  if not more then return end;id=nextid
  for _,e in ipairs(more) do extras[owner][#extras[owner]+1]=e;local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height;if e.direction%8==4 then w,h=h,w end
   for x=math.floor(e.position.x-w/2+.001),math.ceil(e.position.x+w/2-.001)-1 do for y=math.floor(e.position.y-h/2+.001),math.ceil(e.position.y+h/2-.001)-1 do occupied[owner][key(x,y)]=true end end
  end
  for _,g in ipairs(empty) do guards[owner][#guards[owner]+1]=g;occupied[owner][key(g.x,g.y)]=true end
  return ports
 end
 local function balance(owner,p)
  local v=vec[p.direction or 8]
  for lead=0,12 do
   local candidate={};local nextid=id
   for n=1,lead do candidate[#candidate+1]={entity_number=nextid,name=settings.belt_out,position={x=p.x+.5+v[1]*n,y=p.y+.5+v[2]*n},direction=p.direction or 8};nextid=nextid+1 end
   local x,y=p.x+v[1]*lead,p.y+v[2]*lead
   local out;nextid,out=lane_balance.emit(candidate,nextid,settings.belt_out,settings.splitter,x,y,p.direction or 8,true)
   local guard={x=x+v[2],y=y-v[1]};local used={};local valid=not occupied[owner][key(guard.x,guard.y)]
   for _,e in ipairs(candidate) do local q=prototypes.entity[e.name];local w,h=q.tile_width,q.tile_height;if e.direction%8==4 then w,h=h,w end
    for xx=math.floor(e.position.x-w/2+.001),math.ceil(e.position.x+w/2-.001)-1 do for yy=math.floor(e.position.y-h/2+.001),math.ceil(e.position.y+h/2-.001)-1 do local k=key(xx,yy);if occupied[owner][k] or used[k] then valid=false end;used[k]=true end end
   end
   if valid and not used[key(guard.x,guard.y)] then
    for _,e in ipairs(candidate) do extras[owner][#extras[owner]+1]=e end
    for k in pairs(used) do occupied[owner][k]=true end;occupied[owner][key(guard.x,guard.y)]=true;guards[owner][#guards[owner]+1]=guard;id=nextid
    return out
   end
  end
 end
 for _,s in ipairs(sources) do
  outputs[s.bi]=outputs[s.bi] or {}
  if #s.links>0 then local ports=build(s.bi,s.port,s.links,false);if not ports then return start,sequence,false end
   local base=capacity.flow(bs[s.bi].recipe_node.products[1],bs[s.bi].recipe_node)
   for i,p in ipairs(ports) do local e=s.links[i]
    -- Splitters balance belts, not lanes. Normalize each contributing stream
    -- before a merge or a later side-loading header can select unequal lanes.
    if #e.target.links>1 and (s.asymmetric or s.pooled or #s.links>1) then
     local q=balance(s.bi,p);if not q then return start,sequence,false end;p=q
    end
    p.share=e.rate/base;p.flow_edge=not e.terminal and e.id or nil;p.terminal_slot=e.slot;p.graph_terminal=not not e.terminal;outputs[s.bi][#outputs[s.bi]+1]=p end
  end
 end
 for _,t in ipairs(sinks) do if not t.terminal then
  local ports=build(t.bi,t.port,t.links,true);if not ports then return start,sequence,false end
  inputs[t.bi]=inputs[t.bi] or {};inputs[t.bi][t.port]={}
  for i,p in ipairs(ports) do local q=work.copy(t.port);q.x,q.y,q.direction=p.x,p.y,p.direction;q.graph_rate=t.links[i].rate;q.layout_rate=q.graph_rate;q.flow_edge=t.links[i].id;inputs[t.bi][t.port][#inputs[t.bi][t.port]+1]=q end
 end end
 -- Commit only after every junction of this resource fits its own block.
 local result={}
 for bi,b in ipairs(bs) do local first=#result+1
  for i=b.entity_first,b.entity_last do result[#result+1]=es[i] end
  for _,e in ipairs(extras[bi]) do result[#result+1]=e end
  b.entity_first,b.entity_last=first,#result
  for _,g in ipairs(guards[bi]) do b.junction_guards=b.junction_guards or {};b.junction_guards[#b.junction_guards+1]=g end
  if outputs[bi] then b.output_ports=outputs[bi];b.product_out=b.output_ports[1] and work.copy(b.output_ports[1]) or nil;b.graph_bound=true end
  if inputs[bi] then local ps={};for _,p in ipairs(b.inputs) do for _,q in ipairs(inputs[bi][p] or {p}) do ps[#ps+1]=q end end;b.inputs=ps;b.graph_bound=true end
 end
 for i=#es,1,-1 do es[i]=nil end;for i,e in ipairs(result) do es[i]=e end
 return id,sequence,true
end
local function step(a,s)
 if not s.es then
  s.copy_entities=s.copy_entities or {};local done,es=work.copy_step(a.entities,s.copy_entities)
  if not done then return false end
  s.es=es;s.copy_entities=nil
 end
 if not s.bs then
  s.copy_blocks=s.copy_blocks or {};local done,bs=work.copy_step(a.blocks,s.copy_blocks)
  if not done then return false end
  s.bs=bs;s.copy_blocks=nil
 end
 if not s.names then s.id=a.id;s.sequence=0;s.index=1;s.names={};s.exports={};s.count=0
  local names={};for _,b in ipairs(s.bs) do for _,p in ipairs(b.recipe_node.products or {}) do if p.type~='fluid' then names[p.name]=true end end end
  for name in pairs(names) do s.names[#s.names+1]=name end;table.sort(s.names)
  for _,p in ipairs(a.requirements) do if p.type=='item' then s.exports[p.name]=p.rate end end
 end
 while s.index<=#s.names do
  if not work.consume(64) then return false end
  local ok;s.id,s.sequence,ok=resource(s.es,s.bs,s.names[s.index],s.exports,a.settings,s.id,s.sequence)
  if ok then s.count=s.count+1 end;s.index=s.index+1
  if work.is_active() and s.index<=#s.names then return false end
 end
 for _,b in ipairs(s.bs) do if b.graph_bound and b.output_ports then
  local internal,terminal=false,false
  for _,p in ipairs(b.output_ports) do if p.flow_edge then internal=true end;if p.graph_terminal then terminal=true end end
  b.layout_terminal_only=terminal and not internal
  if b.spatial_group then b.spatial_group=b.spatial_group..'/'..(terminal and (internal and 'mixed' or 'terminal') or internal and 'internal' or 'spare') end
 end end
 return true,{entities=s.es,blocks=s.bs,id=s.id,count=s.count}
end
work.register('preplanned-junctions',step)
function M.apply(es,bs,settings,id,requirements,catalog)
 local belt=settings.belt_out;if capacity.belt(settings.belt_in)>capacity.belt(belt) then belt=settings.belt_in end
 local p=prototypes.entity[belt];local splitter
 for _,name in ipairs(catalog.splitters or {}) do local q=prototypes.entity[name]
  if q.belt_speed>=p.belt_speed and q.tile_width==2 and q.tile_height==1 and (not splitter or q.belt_speed<prototypes.entity[splitter].belt_speed) then splitter=name end
 end
 if not splitter and settings.distribution_mode~='containers' then return id,0 end
 local context
 if settings.distribution_mode=='containers' then
  local hub_settings={};for k,v in pairs(settings) do hub_settings[k]=v end;hub_settings.belt_in=belt
  context=containers.context(hub_settings)
 end
 local result=work.operation('preplanned-junctions',nil,{entities=es,blocks=bs,id=id,requirements=requirements,settings={belt_out=belt,export_capacity=capacity.belt(settings.belt_out),splitter=splitter,container_context=context}})
 for i=#es,1,-1 do es[i]=nil end;for i,e in ipairs(result.entities) do es[i]=e end
 for i=#bs,1,-1 do bs[i]=nil end;for i,b in ipairs(result.blocks) do bs[i]=b end
 return result.id,result.count
end
return M
